#!/usr/bin/perl -w
###############################################################################
# $Id$
###############################################################################
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
###############################################################################

=head1 NAME

VCL::Core::State - VCL state base module

=head1 SYNOPSIS

 use base qw(VCL::Module::State);

=head1 DESCRIPTION

 This is the base module for all of the state objects which are instantiated by
 vcld (new.pm, reserved.pm, etc).

=cut

##############################################################################
package VCL::Module::State;

# Specify the lib path using FindBin
use FindBin;
use lib "$FindBin::Bin/../..";

# Configure inheritance
use base qw(VCL::Module);

# Specify the version of this module
our $VERSION = '2.3';

# Specify the version of Perl to use
use 5.008000;

use strict;
use warnings;
use diagnostics;
use English '-no_match_vars';

use VCL::utils;
use VCL::DataStructure;

##############################################################################

=head1 OBJECT METHODS

=cut

#/////////////////////////////////////////////////////////////////////////////

=head2 initialize

 Parameters  : none
 Returns     : boolean
 Description : Prepares VCL::Module::State objects to process a reservation.
               - Renames the process
               - Updates reservation.lastcheck
               - Creates OS, management node OS, VM host OS (conditional), and
                 provisioner objects
               - If this is a cluster request parent reservation, waits for
                 child reservations to begin
               - Updates request.state to 'pending'

=cut

sub initialize {
	my $self = shift;
	notify($ERRORS{'DEBUG'}, 0, "initializing VCL::Module::State object");
	
	$self->{start_time} = time;
	
	my $request_id = $self->data->get_request_id();
	my $reservation_id = $self->data->get_reservation_id();
	my $request_state_name = $self->data->get_request_state_name();
	my $computer_id = $self->data->get_computer_id();
	my $is_vm = $self->data->get_computer_vmhost_id(0);
	my $is_parent_reservation = $self->data->is_parent_reservation();
	my $reservation_count = $self->data->get_reservation_count();
	
	# Initialize the database handle count
	$ENV{dbh_count} = 0;
	
	# Attempt to get a database handle
	if ($ENV{dbh} = getnewdbh()) {
		notify($ERRORS{'DEBUG'}, 0, "obtained a database handle for this state process, stored as \$ENV{dbh}");
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "unable to obtain a database handle for this state process");
		return;
	}
	
	# Rename this process to include some request info
	rename_vcld_process($self->data);
	
	# Update reservation lastcheck value to prevent processes from being forked over and over if a problem occurs
	my $reservation_lastcheck = update_reservation_lastcheck($reservation_id);
	if ($reservation_lastcheck) {
		$self->data->set_reservation_lastcheck_time($reservation_lastcheck);
	}
	
	# TODO: Move this (VCL-711)
	# Check the image OS before creating OS object
	if (!$self->check_image_os()) {
		notify($ERRORS{'WARNING'}, 0, "failed to check if image OS is correct");
		return;
	}
	
	# Set the PARENTIMAGE and SUBIMAGE keys in the request data hash
	# These are deprecated, DataStructure's is_parent_reservation function should be used
	$self->data->get_request_data->{PARENTIMAGE} = ($self->data->is_parent_reservation() + 0);
	$self->data->get_request_data->{SUBIMAGE}    = (!$self->data->is_parent_reservation() + 0);
	
	# Set the parent PID and this process's PID in the hash
	set_hash_process_id($self->data->get_request_data);
	
	# Create a management node OS object
	# Check to make sure the object currently being created is not a MN OS object to avoid endless loop
	if (my $mn_os = $self->create_mn_os_object()) {
		$self->set_mn_os($mn_os);
		$self->data->set_mn_os($mn_os);
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to create management node OS object");
		return;
	}
	
	# Create an OS object
	if (my $os = $self->create_os_object()) {
		$self->set_os($os);
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to create OS object");
		return;
	}
	
	# Create a VM host OS object if vmhostid is set for the computer
	my $vmhost_os;
	if ($is_vm) {
		$vmhost_os = $self->create_vmhost_os_object();
		if (!$vmhost_os) {
			notify($ERRORS{'WARNING'}, 0, "failed to create VM host OS object");
			return;
		}
		$self->set_vmhost_os($vmhost_os);
	}
	
	# Create a provisioning object
	if (my $provisioner = $self->create_provisioning_object()) {
		$self->set_provisioner($provisioner);
		
		# Allow the provisioning object to access the OS object
		$self->provisioner->set_os($self->os());
		
		# Allow the OS object to access the provisioning object
		# This is necessary to allow the OS code to be able to call the provisioning power* subroutines if the OS reboot or shutdown fails
		$self->os->set_provisioner($self->provisioner());
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to create provisioning object");
		return;
	}
	
	# Create a VM host OS object if vmhostid is set for the computer
	if ($is_vm) {
		# Check if provisioning object already has a VM host OS object
		my $provisioner_vmhost_os = $self->provisioner->vmhost_os(0);
		
		if (ref($provisioner_vmhost_os) ne ref($vmhost_os)) {
			$self->set_vmhost_os($provisioner_vmhost_os);
		}
	}
	
	# Parent reservation needs to update the request state to pending
	if ($is_parent_reservation) {
		# Check if this is a cluster request - don't update the request state until all child reservation processes have started
		# Otherwise, child reservations assigned to other management nodes won't launch
		if ($reservation_count > 1) {
			# Wait for all child processes to begin
			if (!$self->wait_for_child_reservations_to_begin('begin', 60, 3)) {
				$self->reservation_failed("child reservation processes failed begin");
			}
		}
		
		# Update the request state to pending
		if (!update_request_state($request_id, "pending", $request_state_name)) {
			notify($ERRORS{'CRITICAL'}, 0, "failed to update request state to pending");
		}
	}
	
	return 1;
} ## end sub initialize

#/////////////////////////////////////////////////////////////////////////////

=head2 reservation_failed

 Parameters  : $message
 Returns     : exits
 Description : Performs the steps required when a reservation fails:
               - Checks if request was deleted, if so:
                 - Sets computer.state to 'available'
                 - Exits with status 0
               - Inserts 'failed' computerloadlog table entry
               - Updates log.ending to 'failed'
               - Updates computer.state to 'failed'
               - Updates request.state to 'failed', laststate to request's
                 previous state
               - Removes computer from blockcomputers table if this is a block
                 request
               - Exits with status 1

=cut

sub reservation_failed {
	my $self = shift;
	if (ref($self) !~ /VCL::/) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method, reservation failure tasks not attempted, process exiting");
		exit 1;
	}

	# Check if a message was passed as an argument
	my $message = shift;
	if (!$message) {
		$message = 'reservation failed';
	}

	# Get the required data
	my $request_id                  = $self->data->get_request_id();
	my $request_logid               = $self->data->get_request_log_id();
	my $reservation_id              = $self->data->get_reservation_id();
	my $computer_id                 = $self->data->get_computer_id();
	my $computer_short_name         = $self->data->get_computer_short_name();
	my $request_state_name          = $self->data->get_request_state_name();
	my $request_laststate_name      = $self->data->get_request_laststate_name();
	my $computer_state_name         = $self->data->get_computer_state_name();

	# Check if the request has been deleted
	if (is_request_deleted($request_id)) {
		notify($ERRORS{'OK'}, 0, "request has been deleted, setting computer state to available and exiting");

		# Update the computer state to available
		if ($computer_state_name !~ /^(maintenance)/){
			if (update_computer_state($computer_id, "available")) {
				notify($ERRORS{'OK'}, 0, "$computer_short_name ($computer_id) state set to 'available'");
			}
			else {
				notify($ERRORS{'OK'}, 0, "failed to set $computer_short_name ($computer_id) state to 'available'");
			}
		}
		else {
			notify($ERRORS{'WARNING'}, 0, "computer $computer_short_name ($computer_id) state NOT set to available because the current state is $computer_state_name");
		}

		notify($ERRORS{'OK'}, 0, "exiting 0");
		exit 0;
	} ## end if (is_request_deleted($request_id))

	# Display the message
	notify($ERRORS{'CRITICAL'}, 0, "reservation failed on $computer_short_name: $message");

	# Insert a row into the computerloadlog table
	if (insertloadlog($reservation_id, $computer_id, "failed", $message)) {
		notify($ERRORS{'OK'}, 0, "inserted computerloadlog entry");
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to insert computerloadlog entry");
	}
	
	
	if ($request_state_name =~ /^(new|reserved|inuse|image)/){
		# Update log table ending column to failed for this request
		if (update_log_ending($request_logid, "failed")) {
			notify($ERRORS{'OK'}, 0, "updated log ending value to 'failed', logid=$request_logid");
		}
		else {
			notify($ERRORS{'WARNING'}, 0, "failed to update log ending value to 'failed', logid=$request_logid");
		}
	}

	# Update the computer state to failed as long as it's not currently maintenance
	if ($computer_state_name !~ /^(maintenance)/){
		if (update_computer_state($computer_id, "failed")) {
			notify($ERRORS{'OK'}, 0, "computer $computer_short_name ($computer_id) state set to failed");
		}
		else {
			notify($ERRORS{'WARNING'}, 0, "unable to set computer $computer_short_name ($computer_id) state to failed");
		}
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "computer $computer_short_name ($computer_id) state NOT set to failed because the current state is $computer_state_name");
	}

	# Update the request state to failed
	if (update_request_state($request_id, "failed", $request_laststate_name)) {
		notify($ERRORS{'OK'}, 0, "set request state to 'failed'/'$request_laststate_name'");
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "unable to set request to 'failed'/'$request_laststate_name'");
	}

	# Check if computer is part of a blockrequest, if so pull out of blockcomputers table
	if (is_inblockrequest($computer_id)) {
		notify($ERRORS{'OK'}, 0, "$computer_short_name in blockcomputers table");
		if (clearfromblockrequest($computer_id)) {
			notify($ERRORS{'OK'}, 0, "removed $computer_short_name from blockcomputers table");
		}
		else {
			notify($ERRORS{'CRITICAL'}, 0, "failed to remove $computer_short_name from blockcomputers table");
		}
	}
	else {
		notify($ERRORS{'OK'}, 0, "$computer_short_name is NOT in blockcomputers table");
	}

	notify($ERRORS{'OK'}, 0, "exiting 1");
	exit 1;
} ## end sub reservation_failed

#/////////////////////////////////////////////////////////////////////////////

=head2 check_image_os

 Parameters  :
 Returns     :
 Description :

=cut


sub check_image_os {
	my $self               = shift;
	my $request_state_name = $self->data->get_request_state_name();
	my $image_id           = $self->data->get_image_id();
	my $image_name         = $self->data->get_image_name();
	my $image_os_name      = $self->data->get_image_os_name();
	my $imagerevision_id   = $self->data->get_imagerevision_id();
	my $image_architecture    = $self->data->get_image_architecture();

	# Only make corrections if state is image
	if ($request_state_name ne 'image') {
		notify($ERRORS{'DEBUG'}, 0, "no corrections need to be made, not an imaging request, returning 1");
		return 1;
	}

	my $image_os_name_new;
	if ($image_os_name =~ /^(rh)el[s]?([0-9])/ || $image_os_name =~ /^rh(fc)([0-9])/) {
		# Change rhelX --> rhXimage, rhfcX --> fcXimage
		$image_os_name_new = "$1$2image";
	}
	elsif($image_os_name =~ /^(centos)([0-9])/) {
		# Change rhelX --> rhXimage, rhfcX --> fcXimage
		$image_os_name_new = "$1$2image";
	}
	elsif ($image_os_name =~ /^(fedora)([0-9])/) {
		# Change fedoraX --> fcXimage
		$image_os_name_new = "fc$1image"
   }

	else {
		notify($ERRORS{'DEBUG'}, 0, "no corrections need to be made to image OS: $image_os_name");
		return 1;
	}

	# Change the image name
	$image_name =~ /^[^-]+-(.*)/;
	my $image_name_new = "$image_os_name_new-$1";
	
	my $new_architecture = $image_architecture;
	if ($image_architecture eq "x86_64" ) {
		$new_architecture = "x86";
	}

	notify($ERRORS{'OK'}, 0, "Kickstart image OS needs to be changed: $image_os_name -> $image_os_name_new, image name: $image_name -> $image_name_new");

	# Update the image table, change the OS for this image
	my $sql_statement = "
	UPDATE
	OS,
	image,
	imagerevision
	SET
	image.OSid = OS.id,
	image.architecture = \'$new_architecture'\,
	image.name = \'$image_name_new\',
	imagerevision.imagename = \'$image_name_new\'
	WHERE
	image.id = $image_id
	AND imagerevision.id = $imagerevision_id
	AND OS.name = \'$image_os_name_new\'
	";

	# Update the image and imagerevision tables
	if (database_execute($sql_statement)) {
		notify($ERRORS{'OK'}, 0, "image($image_id) and imagerevision($imagerevision_id) tables updated: $image_name -> $image_name_new");
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to update image and imagerevision tables: $image_name -> $image_name_new, returning 0");
		return 0;
	}

	if ($self->data->refresh()) {
		notify($ERRORS{'DEBUG'}, 0, "DataStructure refreshed after correcting image OS");
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to update DataStructure updated correcting image OS, returning 0");
		return 0;
	}
	
	notify($ERRORS{'DEBUG'}, 0, "returning 1");
	return 1;
} ## end sub check_image_os

#/////////////////////////////////////////////////////////////////////////////

=head2 does_loadstate_entry_exist

 Parameters  : $loadstate_name, $ignore_current_reservation (optional)
 Returns     : boolean
 Description : Checks the computerloadlog entries for all reservations belonging
               to the request. True is returned if an entry matching the
               $loadstate_name argument exists for all reservations. The
               $ignore_current_reservation argument may be used to check all
               reservations other than the one currently being processed. This
               may be used by a parent reservation to determine when all child
               reservations have begun to be processed.

=cut

sub does_loadstate_entry_exist {
	my $self = shift;
	if (ref($self) !~ /VCL/) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine can only be called as a class method of a VCL object");
		return;
	}
	
	my $loadstate_name = shift;
	if (!defined($loadstate_name)) {
		notify($ERRORS{'WARNING'}, 0, "computerloadlog loadstate name argument was not supplied");
		return;
	}
	
	my $ignore_current_reservation = shift;
	
	my $request_id = $self->data->get_request_id();
	my $request_state = $self->data->get_request_state_name();
	my $reservation_id = $self->data->get_reservation_id();
	
	# Retrieve computerloadlog entries for all reservations
	my $request_loadstate_names = get_request_loadstate_names($request_id);
	if (!$request_loadstate_names) {
		notify($ERRORS{'WARNING'}, 0, "failed to retrieve request loadstate names");
		return;
	}
	
	my @exists;
	my @does_not_exist;
	my @failed;
	for my $check_reservation_id (keys %$request_loadstate_names) {
		# Ignore the current reservation
		if ($ignore_current_reservation && $check_reservation_id eq $reservation_id) {
			next;
		}
		
		my @loadstate_names = @{$request_loadstate_names->{$check_reservation_id}};
		if (grep { $_ eq $loadstate_name } @loadstate_names) {
			push @exists, $check_reservation_id;
		}
		else {
			push @does_not_exist, $check_reservation_id;
		}
		
		if (grep { $_ eq 'failed' } @loadstate_names) {
			push @failed, $check_reservation_id;
		}
	}
	
	# Check if any child reservations failed
	if (@failed) {
		$self->reservation_failed("child reservation process failed: " . join(', ', @failed));
		return;
	}
	
	if (@does_not_exist) {
		notify($ERRORS{'DEBUG'}, 0, "computerloadlog '$loadstate_name' entry does NOT exist for all reservations:\n" .
			"exists for reservation IDs: " . join(', ', @exists) . "\n" .
			"does not exist for reservation IDs: " . join(', ', @does_not_exist)
		);
		return 0;
	}
	else {
		notify($ERRORS{'DEBUG'}, 0, "computerloadlog '$loadstate_name' entry exists for all reservations");
		return 1;
	}
}

#/////////////////////////////////////////////////////////////////////////////

=head2 wait_for_child_reservations_to_begin

 Parameters  : $loadstate_name (optional), $total_wait_seconds (optional), $attempt_delay_seconds (optional)
 Returns     : boolean
 Description : Loops until a computerloadlog entry exists for all child
               reservations matching the loadstate specified by the
               $loadstate_name argument. Returns false if the loop times out.
               Exits if the request has been deleted. The default
               $total_wait_seconds value is 300 seconds. The default
               $attempt_delay_seconds value is 15 seconds.

=cut

sub wait_for_child_reservations_to_begin {
	my $self = shift;
	if (ref($self) !~ /VCL/) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine can only be called as a class method of a VCL object");
		return;
	}
	
	my $loadstate_name = shift;
	if (!$loadstate_name) {
		notify($ERRORS{'WARNING'}, 0, "computerloadlog loadstate name argument was not supplied");
		return;
	}
	
	my $total_wait_seconds = shift || 300;
	my $attempt_delay_seconds = shift || 15;
	
	my $request_id = $self->data->get_request_id();
	my $request_state_name = $self->data->get_request_state_name();
	
	return $self->code_loop_timeout(
		sub {
			if ($request_state_name ne 'deleted' && is_request_deleted($request_id)) {
				notify($ERRORS{'OK'}, 0, "request has been deleted, exiting");
				exit;
			}
			
			return $self->does_loadstate_entry_exist($loadstate_name, 1);
		},
		[],
		"waiting for child reservation processes to begin", $total_wait_seconds, $attempt_delay_seconds
	);
}

#/////////////////////////////////////////////////////////////////////////////

=head2 DESTROY

 Parameters  : none
 Returns     : exits
 Description : Performs VCL::State module cleanup actions:
               - Removes computerloadlog 'begin' entries for reservation
               - If this is a cluster parent reservation, removes
                 computerloadlog 'begin' entries for all reservations in request
               - Closes the database connection

=cut

sub DESTROY {
	my $self = shift;
	
	my $address = sprintf('%x', $self);
	#notify($ERRORS{'DEBUG'}, 0, ref($self) . " destructor called, address: $address");
	
	# If not a blockrequest, delete computerloadlog entry
	if ($self && $self->data && !$self->data->is_blockrequest()) {
		my $request_id = $self->data->get_request_id();
		my @reservation_ids = $self->data->get_reservation_ids();
		my $is_parent_reservation = $self->data->is_parent_reservation();
		
		if (@reservation_ids) {
			if ($is_parent_reservation) {
				# Delete all computerloadlog rows with loadstatename = 'begin' for all reservations in this request
				delete_computerloadlog_reservation(\@reservation_ids, 'begin');
				get_request_loadstate_names($request_id);
			}
			else {
				notify($ERRORS{'DEBUG'}, 0, "child reservation, computerloadlog 'begin' entries not removed");
			}
		}
		else {
			notify($ERRORS{'WARNING'}, 0, "failed to retrieve the reservation ID, computerloadlog 'begin' rows not removed");
		}
	}

	# Print the number of database handles this process created for testing/development
	if (defined $ENV{dbh_count}) {
		#notify($ERRORS{'DEBUG'}, 0, "number of database handles state process created: $ENV{dbh_count}");
	}
	else {
		notify($ERRORS{'DEBUG'}, 0, "state process created unknown number of database handles, \$ENV{dbh_count} is undefined");
	}
	
	if (defined $ENV{database_select_count}) {
		#notify($ERRORS{'DEBUG'}, 0, "database select queries: $ENV{database_select_count}");
	}
	
	if (defined $ENV{database_select_calls}) {
		my $database_select_calls_string;
		my %hash = %{$ENV{database_select_calls}};
		my @sorted_keys = sort { $hash{$b} <=> $hash{$a} } keys(%hash);
		for my $key (@sorted_keys) {
			$database_select_calls_string .= "$ENV{database_select_calls}{$key}: $key\n";
		}
		
		#notify($ERRORS{'DEBUG'}, 0, "database select called from:\n$database_select_calls_string");
	}
	
	if (defined $ENV{database_execute_count}) {
		#notify($ERRORS{'DEBUG'}, 0, "database execute queries: $ENV{database_execute_count}");
	}

	# Close the database handle
	if (defined $ENV{dbh}) {
		#notify($ERRORS{'DEBUG'}, 0, "process has a database handle stored in \$ENV{dbh}, attempting disconnect");

		if ($ENV{dbh}->disconnect) {
			#notify($ERRORS{'DEBUG'}, 0, "\$ENV{dbh}: database disconnect successful");
		}
		else {
			notify($ERRORS{'WARNING'}, 0, "\$ENV{dbh}: database disconnect failed, " . DBI::errstr());
		}
	} ## end if (defined $ENV{dbh})
	else {
		#notify($ERRORS{'DEBUG'}, 0, "process does not have a database handle stored in \$ENV{dbh}");
	}

	# Check for an overridden destructor
	$self->SUPER::DESTROY if $self->can("SUPER::DESTROY");
	
	# Determine how long process took to run
	if ($self->{start_time}) {
		my $duration = (time - $self->{start_time});
		notify($ERRORS{'OK'}, 0, ref($self) . " process duration: $duration seconds");
	}
} ## end sub DESTROY

#/////////////////////////////////////////////////////////////////////////////

1;
__END__

=head1 SEE ALSO

L<http://cwiki.apache.org/VCL/>

=cut

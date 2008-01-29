=begin comment
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@

File:
	Insteon_Link.pm

Description:
	Generic class implementation of a Insteon Device.

Author(s):
	Gregg Liming / gregg@limings.net
	Jason Sharpee / jason@sharpee.com

License:
	This free software is licensed under the terms of the GNU public license.

Usage:

	$insteon_family_movie = new Insteon_Device($myPIM,30,1);

	$insteon_familty_movie->set("on");

Special Thanks to:
	Bruce Winter - MH

@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
=cut

use Insteon_Device;

use strict;
package Insteon_Link;

@Insteon_Link::ISA = ('Insteon_Device');


sub new
{
	my ($class,$p_interface,$p_deviceid) = @_;

	# note that $p_deviceid will be 00.00.00:<groupnum> if the link uses the interface as the controller
	my $self = $class->SUPER::new($p_interface,$p_deviceid);
	bless $self,$class;
# don't apply ping timer to this class
	$$self{ping_timer}->stop();
	return $self;
}

sub add 
{
	my ($self, $obj, $on_level, $ramp_rate) = @_;
	if (ref $obj and ($obj->isa('Insteon_Device') or $obj->isa('Light_Item'))) {
		if ($$self{members} && $$self{members}{$obj}) {
			print "[Insteon_Link] An object (" . $obj->{object_name} . ") already exists "
				. "in this scene.  Aborting add request.\n";
			return;
		}
		$on_level = '100%' unless $on_level;
		$$self{members}{$obj}{on_level} = $on_level;
		$$self{members}{$obj}{object} = $obj;
		$ramp_rate =~ s/s$//i;
		$$self{members}{$obj}{ramp_rate} = $ramp_rate if defined $ramp_rate;
	} else {
		&::print_log("[Insteon_Link] WARN: unable to add $obj as items of this type are not supported!");
        }
}

sub is_plm_controlled
{
	my ($self) = @_;
	return $self->device_id eq '000000';
}


sub sync_links
{
	my ($self) = @_;
	@{$$self{sync_queue}} = (); # reset the work queue
	my $insteon_object = $self->interface;
	if (!($self->is_plm_controlled)) {
		$insteon_object = $self->interface->get_object($self->device_id,'01');
	}
	my $self_link_name = $self->get_object_name;
	if ($$self{members}) {
		foreach my $member_ref (keys %{$$self{members}}) {
			my $member = $$self{members}{$member_ref}{object};
			# find real device if member is a Light_Item
			if ($member->isa('Light_Item')) {
				my @children = $member->find_members('Insteon_Device');
				$member = $children[0];
			}
			# find real device if member's group is not '01'; for example, cross-linked KeypadLincs
			if ($member->group ne '01') {
				$member = $self->interface->get_object($member->device_id,'01');
			}
			my $tgt_on_level = $$self{members}{$member_ref}{on_level};
			$tgt_on_level = '100%' unless defined $tgt_on_level;

			my $tgt_ramp_rate = $$self{members}{$member_ref}{ramp_rate};
			$tgt_ramp_rate = '0' unless defined $tgt_ramp_rate;
			# first, check existance for each link; if found, then perform an update (unless link is to PLM)
			# if not, then add the link
			if ($member->has_link($insteon_object, $self->group, 0)) {
				# TO-DO: only update link if the on_level and ramp_rate are different
				my $requires_update = 0;
				$tgt_on_level =~ s/(\d+)%?/$1/;
				$tgt_ramp_rate =~ s/(\d)s?/$1/;
				my $adlbkey = lc $insteon_object->device_id . $self->group . '0';
				if (!($member->is_dimmable)) {
					if ($tgt_on_level >= 1 and $$member{adlb}{$adlbkey}{data1} ne 'ff') {
						$requires_update = 1;
						$tgt_on_level = 100;
					} elsif ($tgt_on_level == 0 and $$member{adlb}{$adlbkey}{data1} ne '00') {
						$requires_update = 1;
					}
					if ($$member{adlb}{$adlbkey}{data2} ne '00') {
						$tgt_ramp_rate = 0;
					}
				} else {
					$tgt_ramp_rate = 0.1 unless $tgt_ramp_rate;
					my $link_on_level = hex($$member{adlb}{$adlbkey}{data1})/2.55;
					my $raw_ramp_rate = $$member{adlb}{$adlbkey}{data2};
					my $link_ramp_rate = &Insteon_Device::get_ramp_from_code($raw_ramp_rate);
#					&::print_log("[Insteon_Link] " . $self->get_object_name . ": " . $member->get_object_name 
#						. " tgt_on_level=$tgt_on_level, link_on_level=$link_on_level, "
#						. "tgt_ramp_rate=$tgt_ramp_rate, link_ramp_rate=$link_ramp_rate");
					if ($link_ramp_rate != $tgt_ramp_rate) {
						$requires_update = 1;
					} elsif (($link_on_level > $tgt_on_level + 1) or ($link_on_level < $tgt_on_level -1)) {
						$requires_update = 1;
					}
				}
				if ($requires_update) {
					my %link_req = ( member => $member, cmd => 'update', object => $insteon_object, 
						group => $self->group, is_controller => 0, 
						on_level => $tgt_on_level, ramp_rate => $tgt_ramp_rate,
						callback => "$self_link_name->_process_sync_queue()" );
					push @{$$self{sync_queue}}, \%link_req;
				}
			} else {
				my %link_req = ( member => $member, cmd => 'add', object => $insteon_object, 
					group => $self->group, is_controller => 0, 
					on_level => $tgt_on_level, ramp_rate => $tgt_ramp_rate,
					callback => "$self_link_name->_process_sync_queue()" );
				push @{$$self{sync_queue}}, \%link_req;
			}
			if (!($insteon_object->has_link($member, $self->group, 1))) {
				my %link_req = ( member => $insteon_object, cmd => 'add', object => $member, 
					group => $self->group, is_controller => 1, 
					callback => "$self_link_name->_process_sync_queue()" );
				# set data3 is device is a KeypadLinc
				$link_req{data3} = $self->group if $$insteon_object{devcat} eq '0109';
				push @{$$self{sync_queue}}, \%link_req;
			}
		}
	}
	# if not a plm controlled link, then confirm that a link back to the plm exists
	if (!($self->is_plm_controlled)) {
		if (!($insteon_object->has_link($self->interface,'01',1))) {
			my %link_req = ( member => $insteon_object, cmd => 'add', object => $self->interface, 
				group => '01', is_controller => 1, 
				callback => "$self_link_name->_process_sync_queue()" );
			$link_req{data3} = $self->group if $$insteon_object{devcat} eq '0109';
			push @{$$self{sync_queue}}, \%link_req;
		}
		if (!($self->interface->has_link($insteon_object,'01',0))) {
			my %link_req = ( member => $self->interface, cmd => 'add', object => $insteon_object, 
				group => '01', is_controller => 0, 
				callback => "$self_link_name->_process_sync_queue()" );
			push @{$$self{sync_queue}}, \%link_req;
		}
	}
	if (@{$$self{sync_queue}}) {
		$self->_process_sync_queue();
	}
	
	# TO-DO: consult links table to determine if any "orphaned links" refer to this device; if so, then delete
	# WARN: can't immediately do this as the link tables aren't finalized on the above operations
	#    until the end of the actual insteon memory poke sequences; therefore, may need to handle separately
}

sub _process_sync_queue {
	my ($self) = @_;
	# get next in queue if it exists
	if (@{$$self{sync_queue}}) {
		my $link_req_ptr = shift(@{$$self{sync_queue}});
		my %link_req = %$link_req_ptr;
		if ($link_req{cmd} eq 'update') {
			my $link_member = $link_req{member};
			$link_member->update_link(%link_req);
		} elsif ($link_req{cmd} eq 'add') {
			my $link_member = $link_req{member};
			$link_member->add_link(%link_req);
		} 
	}
}

sub set
{
	my ($self, $p_state, $p_setby, $p_respond) = @_;
	# prevent setby internal Insteon_Device timers
	return if $p_setby eq $$self{ping_timer};
	if (!($self->group eq '01')) {
		# iterate over the members
		if ($$self{members}) {
			foreach my $member_ref (keys %{$$self{members}}) {
				my $member = $$self{members}{$member_ref}{object};
				my $on_state = $$self{members}{$member_ref}{on_level};
				$on_state = '100%' unless $on_state;
				my $local_state = $on_state;
				$local_state = 'on' if $local_state eq '100%';
				$local_state = 'off' if $local_state eq '0%';
				if ($member->isa('Light_Item')) {
				# if they are Light_Items, then set their on_dim attrib to the member on level
				#   and then "blank" them via the manual method for a tad over the ramp rate
				#   In addition, locate the Light_Item's Insteon_Device member and do the 
				#   same as if the member were an Insteon_Device
					my $ramp_rate = $$self{members}{$member_ref}{ramp_rate};
					$ramp_rate = 0 unless defined $ramp_rate;
					$ramp_rate = $ramp_rate + 2;
					my @lights = $member->find_members('Insteon_Device');
					if (@lights) {
						my $light = @lights[0];
						# remember the current state to support resume
						$$self{members}{$member_ref}{resume_state} = $light->state;
						$member->manual($light, $ramp_rate);
						$light->set_receive($local_state,$self);
					} else {
						$member->manual(1, $ramp_rate);
					}
					$member->set_on_state($on_state);
				} elsif ($member->isa('Insteon_Device')) {
				# remember the current state to support resume
					$$self{members}{$member_ref}{resume_state} = $member->state;
				# if they are Insteon_Device objects, then simply set_receive their state to 
				#   the member on level
					$member->set_receive($local_state,$self);
				}
			}
		}
	}
	$self->SUPER::set($p_state, $p_setby, $p_respond);
}

#sub restore_string
#{
#	my ($self) = @_;
#	return $self->SUPER::restore_string();
#}

#sub restore_adlb
#{
#	my ($self,$adlb) = @_;
#	return $self->SUPER::restore_adlb($adlb);
#}

sub update_members
{
	my ($self) = @_;
	# iterate over the members
	if ($$self{members}) {
		foreach my $member_ref (keys %{$$self{members}}) {
			my ($device);
			my $member = $$self{members}{$member_ref}{object};
			my $on_state = $$self{members}{$member_ref}{on_level};
			$on_state = '100%' unless $on_state;
			my $ramp_rate = $$self{members}{$member_ref}{ramp_rate};
			$ramp_rate = 0 unless defined $ramp_rate;
			if ($member->isa('Light_Item')) {
			# if they are Light_Items, then locate the Light_Item's Insteon_Device member
				my @lights = $member->find_members('Insteon_Device');
				if (@lights) {
					$device = @lights[0];
				} 
			} elsif ($member->isa('Insteon_Device')) {
				$device = $member;
			}
			if ($device) {
				my %current_record = $device->get_link_record($self->device_id . $self->group);
				if (%current_record) {
					&::print_log("[Insteon_Link] remote record: $current_record{data1}")
						if $::Debug{insteon};
				}
			}
		}
	}
}

sub link_to_interface
{
	my ($self, $p_group, $p_data3) = @_;
	my $group = $p_group;
	$group = $self->group unless $group;
	return if $self->device_id eq '000000'; # don't allow this to be used for PLM links
	# get the surrogate device for this if group is not '01'
	if ($self->group ne '01') {
		my $surrogate_obj = $self->interface->get_object($self->device_id,'01');
		if ($p_data3) {
			$surrogate_obj->link_to_interface($group,$p_data3);
		} elsif ($$surrogate_obj{devcat} eq '0109') {
			$surrogate_obj->link_to_interface($group,$self->group);
		} else {
			$surrogate_obj->link_to_interface($group);
		}
		# next, if the link is a keypadlinc, then create the reverse link to permit
		# control over the button's light
		if ($$surrogate_obj{devcat} eq '0109') { # 0109 is a keypadlinc

		}
	} else {
		if ($p_data3) {
			$self->SUPER::link_to_interface($group, $p_data3);
		} else {
			$self->SUPER::link_to_interface($group);
		}
	}
}

sub unlink_to_interface
{
	my ($self,$p_group) = @_;
	my $group = $p_group;
	$group = $self->group unless $group;
	return if $self->device_id eq '000000'; # don't allow this to be used for PLM links
	# get the surrogate device for this if group is not '01'
	if ($self->group ne '01') {
		my $surrogate_obj = $self->interface->get_object($self->device_id,'01');
		$surrogate_obj->unlink_to_interface($group);
		# next, if the link is a keypadlinc, then delete the reverse link to permit
		# control over the button's light
		if ($$surrogate_obj{devcat} eq '0109') { # 0109 is a keypadlinc

		}
	} else {
		$self->SUPER::unlink_to_interface($group);
	}
}

sub initiate_linking_as_controller
{
	my ($self, $p_group) = @_;
	# iterate over the members
	if ($$self{members}) {
		foreach my $member_ref (keys %{$$self{members}}) {
			my $member = $$self{members}{$member_ref}{object};
			if ($member->isa('Light_Item')) {
			# if they are Light_Items, then set them to manual to avoid automation
			#   while manually setting light parameters
				$member->manual(1,120,120); # 120 seconds should be enough
			} 
		}
	}
	$self->interface()->initiate_linking_as_controller($p_group);
}

sub _xlate_mh_insteon
{
	my ($self, $p_state, $p_type, $p_extra) = @_;
	if ($self->group eq '01') {
		return $self->SUPER::_xlate_mh_insteon($p_state, $p_type, $p_extra);
	} else {
		return $self->SUPER::_xlate_mh_insteon($p_state, 'broadcast', $p_extra);
	}
}

sub request_status
{
	my ($self) = @_;
	&::print_log("[Insteon_Link] requesting status for members of " . $$self{object_name});
	foreach my $member (keys %{$$self{members}}) {
		$$self{members}{$member}{object}->request_status($self);
	}
}

1;

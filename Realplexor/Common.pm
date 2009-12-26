##
## Realplexor shared routines.
##
package Realplexor::Common;
use strict;
use Storage::DataToSend;
use Storage::ConnectedFhs;
use Storage::OnlineTimers;
use Storage::PairsByFhs;
use Storage::CleanupTimers;
use Storage::Events;
use Event::Lib::Connection;
use Event::Lib::Server;
use Connection::Wait;
use Connection::In;
use Realplexor::Config;
use Realplexor::Tools;
use Time::HiRes;
use Digest::MD5;

# Extract pairs [cursor, ID] from the client data. 
# Return [ [cursor1, id1], [cursor2, id2], ... ] or undef if 
# no "identifier" marker is found yet.
#
# If you call this sub in a list context, the second return
# value is the list of IDs marked by "*" at identifier=...
# (this means that these IDs must be listened by a client
# too to receive the data).
#
# If login and password are specified, third return value
# is [login, password] pair.
# 
# Format: 
# - identifier=abc                         [single identifier]
# - identifier=abc,def,ghi                 [multiple identifiers]
# - identifier=12345.23:abc,12345:def      [where 12345... is the cursor]
# - identifier=abc,def,*ghi,*jkl           [multiple ids, and (ghi, jkl) is returned as second list element]
# - identifier=LOGIN:PASS@abc,10:def,*ghi  [same as above, but login and password are specified]
sub extract_pairs {
	my $rdata = \$_[0];
	my $from_in_line = $_[1];
	# Return fast if no identifier marker is presented yet.
	return undef if index($$rdata, "$CONFIG{IDENTIFIER}=") < 0;
	# Identifier marker seems to be presented. Remove referrer headers.
	# TODO: speed optimization.
	my $data = $$rdata; 
	$data =~ s/^[ \t]*Referer:[^\r\n]*//mgi;
	# Now check for identifier freely.
	my ($login, $password, $ids) = $data =~ m{
		\b 
		$CONFIG{IDENTIFIER} =
		(?: (\w+) : ([^@\s]+) @ )?
		([*\w,.:]*)
		# At the end, find a character, NOT end of string! 
		# Because only a chunk may finish, not the whole data.
		[^*\w,.:] 
	}sx or return undef;
	# By default, current HiRes time is returned for cursor.
	# It's very important that time_hi_res() returns Math::BigFloat, because
	# system timer resolution is not enough to differ sequential calls.
	my $time = Realplexor::Tools::time_hi_res();
	my %limit_ids = ();
	my @pairs = map {
		if (m/^ (\*?) (?: (\d+(?:\.\d+)?) : )? (\w+) $/sx) {
			if ($1) {
				# ID with limiter.
				$limit_ids{$3} = 1;
			}
			if (!$1 || !$from_in_line) {
				# Not limiter or limiter, but in WAIT line.
				defined $2 && length($2) ? [ $2, $3 ] : [ $time, $3 ];
			} else {
				();
			}
		} else {
			();
		}
	} split(/,/, $ids);
	return wantarray()? (\@pairs, (%limit_ids? \%limit_ids : undef), ($login? [$login, $password] : undef)) : \@pairs;
}

# Shutdown a connection and remove all references to it.
sub shutdown_fh {
	my ($fh) = @_;
	# Remove all references to $fh from everywhere.
	foreach my $pair (@{$pairs_by_fhs->get_pairs_by_fh($fh)}) {
		$connected_fhs->del_from_id_by_fh($pair->[1], $fh);
	}
	$pairs_by_fhs->remove_by_fh($fh);
	return shutdown($fh, 2);
}

# Send first pending data to clients with specified IDs.
# Remove sent data from the queue and close connections to clients.
sub send_pendings {
	my ($ids) = @_;
	
	# Functions to be called to check data visibility.
	my @visibility_checkers =  (
		\&hook_check_visibility, 
		grep { $_ } ($CONFIG{HOOK_CHECK_VISIBILITY})
	);
	
	# Collect data to be sent to each connection at %data_by_fh.
	# For each connection also collect matched IDs, so each client
	# receives only the list of IDs which is matched by his request
	# (client does not see IDs of other clients).
	my %data_by_fh = ();
	my %fh_by_fh = ();
	my %seen_ids = ();
	foreach my $id (@$ids) {
		# All data items for this ID.
		my $data = $data_to_send->get_data_by_id($id) or next;
		# Who listen this ID.
		my $fhs_hash = $connected_fhs->get_hash_by_id($id) or next;
		while (my ($dummy, $cursor_and_fh) = each %$fhs_hash) {
			# Process a single FH which listens this ID at $cursor.
			my ($listen_cursor, $fh) = @$cursor_and_fh;
			# What other IDs listens this FH.
			my $what_listens_this_fh = $pairs_by_fhs->get_pairs_by_fh($fh);
			$fh_by_fh{$fh} = $fh;
			# Iterate over data items.
			ONE_ITEM:
			foreach my $item (@$data) {
				# Process a single data item in context of this FH.
				my ($cursor, $rdata, $limit_ids) = @$item;
				# Filter data invisible to this client.
				foreach my $func (@visibility_checkers) {
					next ONE_ITEM if !$func->(
						id           => $id,
						cursor        => $cursor,
						rdata        => $rdata,
						limit_ids    => $limit_ids,
						listen_cursor => $listen_cursor,
						listen_pairs => $what_listens_this_fh,
					);
				}
				# Hash by dataref to avoid to send the same data 
				# twice if it is appeared in multiple IDs.
				if (!$data_by_fh{$fh}{$rdata}) {
					$data_by_fh{$fh}{$rdata} = {
						cursor => $cursor, 
						rdata => $rdata, 
						ids   => { $id => $cursor }
					};
				} else {
					# Add new ID to the list of IDs for this data.
					$data_by_fh{$fh}{$rdata}{ids}{$id} = $cursor;
				}
				$seen_ids{$id} = 1;
			}
		}
	}
	
	# Send data to each connection (json array format).
	# Response format is:
	# [
	#   {
	#     "ids": { "id1": cursor1, "id2": cursor2, ... },
	#     "data": <data from server without headers>
	#   },
	#   {
	#     "ids": { "id3": cursor3, "id4": cursor4, ... },
	#     "data": <data from server without headers>
	#   },
	#   ...
	# }
	my @seen_ids = sort keys %seen_ids;
	while (my ($fh, $triples) = each %data_by_fh) {
		my @out = ();
		# Ordering is for better determinism in tests.
		foreach my $triple (sort { $a->{cursor} <=> $b->{cursor} or ${$a->{rdata}} cmp ${$b->{rdata}} } values %$triples) {
			# Build one response block.
			# It's very to send cursors as string to avoid rounding.
			my @ids = 
				map { '"' . $_ . '": "' . $triple->{ids}{$_} . '"' } 
				sort keys %{$triple->{ids}};
			push @out, join "\n",
				'  {',
				'    "ids": { ' . join(", ", @ids) . ' },',
				'    "data":' . (${$triple->{rdata}} =~ /\n/? "\n" : " ") . ${$triple->{rdata}},
				'  }';
		}
		# Join response blocks into one "multipart".
		my $out = "[\n" . join(",\n", @out) . "\n]";
		my $fh = $fh_by_fh{$fh};
		my $r1 = print $fh $out;
		my $r2 = shutdown_fh($fh);
		logger("<- sending " . @out . " responses (" . length($out) . " bytes) from [" . join(", ", @seen_ids) . "] (print=$r1, shutdown=$r2)");
	}
	# Remove old data.
	foreach my $id (@$ids) {
		$data_to_send->clean_old_data_for_id($id, $CONFIG{MAX_DATA_FOR_ID});
	}
}

# Called to check visibility of a data block.
sub hook_check_visibility {
	my (%a) = @_;

#	use Data::Dumper; print Dumper(\%a);
	
	# 1. Filter old data.
	return 0 if $a{cursor} <= $a{listen_cursor};
		
	# 2. If this data block has limited visibility, check that
	#    current client listens at least one ID in the associated
	#    limiter list.
	return 0 if $a{limit_ids} && !grep { $a{limit_ids}{$_->[1]} } @{$a{listen_pairs}};
				
	# OK.
	return 1;
}

# Send IFRAME content.
sub send_static {
	my ($fh, $param, $type) = @_;
	print $fh "HTTP/1.1 200 OK\r\n";
	print $fh "Connection: close\r\n";
	print $fh "Content-Type: $type\r\n";
	print $fh "Last-Modified: " . $CONFIG{"${param}_TIME"} . "\r\n";
	print $fh "Expires: Wed, 08 Jul 2037 22:53:52 GMT\r\n";
	print $fh "Cache-Control: public\r\n";
	print $fh "\r\n";
	print $fh $CONFIG{"${param}_CONTENT"};
	shutdown($fh, 2); # don't use close, it breaks event machine!
}

# Logger routine.
sub logger {
	my ($msg, $nostat) = @_;
	my $verb = defined $CONFIG{VERBOSITY}? $CONFIG{VERBOSITY} : 100;
	return if $verb == 0;
	$msg = $msg . "\n  " . sprintf(
		"[pairs_by_fhs=%d data_to_send=%d connected_fhs=%d online_timers=%d cleanup_timers=%d events=%d]", 
		$pairs_by_fhs->get_num_items(),
		$data_to_send->get_num_items(), 
		$connected_fhs->get_num_items(), 
		$online_timers->get_num_items(),
		$cleanup_timers->get_num_items(),
		$events->get_num_items()
	) if !$nostat && $verb > 1;
	print "[" . localtime(time) . "] $msg\n";
}

return 1;
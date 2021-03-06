#!/usr/bin/perl

use strict;

# ----------------------------------------------------------------------------------

# monFlows v1.2
#
# This script depends on linux-style ps and an existing /tmp directory
#
# You can comment out unneeded tests E.g., if this machine doesn't collect flows,
# then comment out the line:
#      $alertLevel != &checkFlowCapture;
#
#
# MONITORING
# flowage operability is monitored using various checks:
#
#   1) checks for flow storms. Generates an alert when flow file sizes grows
#      larger than $risingThreshold. Generates another alert when the flow file
#      size returns below $fallingThreshold. Look at the file sizes in the flow
#      capture directory to gauge what appropriate values might be.

my %flowDirs = (
	'/var/log/webview/flows/capture' => {
		'name' => 'default',
		'risingThreshold' => 20_000_000,
		'fallingThreshold' => 5_000_000,
	},
);

#   2) checks for SNMP retreivable messages in the stdout file created by cron
#      every time flowage.pl is run.
#
#   3) checks for stuck lock file messages in the log file. These messages indicate
#      that flowage ended prematurely.
#
#   4) checks for no-bucket messages in the log file. These messages indicate that
#      flowage is receiving improper timestamps or has gotten irretrievably out
#      of sync.
#
# The log file(s) to be checked and their corresponding temporary file directories are
# set below:

my %logFileTempDirectory = (
	'/var/log/webview/flows/data/flowage.log' => '/var/log/webview/flows/tmp',
);

# If the $ATTEMPT_FIX global variable is set, then the lock file and no-bucket flow
# problems will be fixed by deleting the offending file.

my $ATTEMPT_FIX = 1;


# if an alertSmtpDestination is set, emails are generated.

my $alertSmtpDestination;	# e.g., 'bobfriendly@acme.com'

# Note: alert email is sent with the local system's 'mail' utility, which
# often uses postfix as a mail transport agent. If email delivery isn't
# working, read up on postfix. For basic relaying to another server,
#  postfix:
#      add "relayhost = [my smtp server]" to /etc/postfix/main.cf
#  mailx + ssmtp:
#      add "mailhub=[my smtp server]" in /etc/ssmtp/ssmtp.conf

# how often should minor alerts be generated?

my $alertMinorFrequency = 3600 * 4;	# no more than one minor alert per four hours
my $alertMajorFrequency = 3600 * 1;	# no more than one major alert per hour


# directory to store data files

my $dataDir; 			# if undefined, will use the same location as the script.


# ----------------------------------------------------------------------------------

use File::stat;

my $acc;			# text accumulator (global)

my @logFiles = keys %logFileTempDirectory;

if (! defined $dataDir) { $0 =~ /^(.*)\/[^\/]+$/; $dataDir = $1 || '.'; }

my $stateFlowFile = "$dataDir/monFlowFiles.state2";
my $stateLogFile = "$dataDir/monFlowLog.state2";
my $stateAlertFile = "$dataDir/monFlowAlert.state2";

my $alertMinor = 0x01;
my $alertMajor = 0x02;

print scalar localtime(), " monFlows v1.1\n";

my $alertLevel = 0;

$alertLevel != &checkTest;		# test email alert

$alertLevel != &checkFlowCapture;	# ensure flow-capture is running

$alertLevel |= &checkFlowFiles;		# ensure flow files are ballpark size

$alertLevel |= &checkFlowageLog;	# check flowage log for evidence of weirdness

$alertLevel |= &checkLockFiles;		# ensure lock file is bound to an active process

# $alertLevel |= &checkStdout;		# check flowage stdout.txt for evidence of SNMP failures

if (length($acc)) {
	$| = 1;
	print join('',  "-" x 72,
		"\n",
		scalar localtime(),
		"\n",
		$acc,
		"\n");

	open(IN, $stateAlertFile);
	chomp ( my $lastAlertMinor = <IN> );
	chomp ( my $lastAlertMajor = <IN> );
	close(IN);

	if ($alertLevel & $alertMajor) {
		if ($lastAlertMajor >= (time - $alertMajorFrequency)) {
			print "\nmajorAlarm not sent\n";
			exit 0;
		}
		$lastAlertMajor = time;
	}
	elsif ($alertLevel & $alertMinor) {
		if ($lastAlertMinor >= (time - $alertMinorFrequency)) {
			print "\nminorAlarm not sent\n";
			exit 0;
		}
		$lastAlertMinor = time;
	}

	open(OUT, '>' . $stateAlertFile);
	print OUT ($lastAlertMinor || 0) . "\n";
	print OUT ($lastAlertMajor || 0) . "\n";
	close(OUT);

	$acc = "Alert generated by $0\n\n" . $acc;

	if (defined $alertSmtpDestination) {
		my $tfile = "/tmp/smtp.$$";

		open(OUT, ">$tfile");
		print OUT $acc;
		close(OUT);

		`mail -s 'Webview NetFlow Reporter alert' $alertSmtpDestination < $tfile`;

		unlink($tfile);
	}
}

sub checkTest
{
	foreach (@ARGV) {
		if (/-test/) {
			$acc .= "Webview NetFlow Reporter test alert\n";
			return $alertMajor;
		}
	}
	return 0;
}

sub checkFlowFiles
{
	my $retCode;

	foreach (keys %flowDirs) {
		$retCode |= &checkFlowDir(
			$_,
			$flowDirs{$_}->{name},
			$flowDirs{$_}->{risingThreshold},
			$flowDirs{$_}->{fallingThreshold},
		);
	}
	return $retCode;
}

sub checkFlowDir
{
	my($flowDir, $name, $risingThreshold, $fallingThreshold) = @_;
	my $retCode;

	my $stateFile = $stateFlowFile . '.' . $name;
	my $dateCutoff = (-f $stateFile) ? stat($stateFile)->mtime : (time - 86400);

	open(IN, $stateFile);
	my $hiccupStart = (<IN> =~ /(\d+)/) ? $1 : 0;
	close(IN);

	print "checking $flowDir\n";

	opendir(DIR, $flowDir);
	foreach (grep /^ft/, readdir(DIR)) {
		$_ = $flowDir . "/$_";
		next if (! -f $_);

		next if (stat($_)->mtime < $dateCutoff);

		if ((! $hiccupStart) && (stat($_)->size >= $risingThreshold)) {
			$acc .= $_ . " size " . stat($_)->size . " > $risingThreshold.\n";
			$acc .= "Flow storm has begun ($name)\n\n";
			$retCode = $alertMajor;
			$hiccupStart = stat($_)->mtime;
		}
		if (($hiccupStart) && (stat($_)->size < $fallingThreshold)) {
			$acc .= $_ . " size " . stat($_)->size . " < $fallingThreshold.\n";
			$acc .= "Flow storm has subsided ($name). Duration=" . (stat($_)->mtime - $hiccupStart) . " seconds\n\n";
			$retCode = $alertMinor;
			undef $hiccupStart;
		}
	}
	closedir(DIR);

	open(OUT, '>' . $stateFile);
	print OUT $hiccupStart, "\n";
	close(OUT);

	return $retCode;
}

sub checkFlowCapture
{
	if ( `ps -f | grep flow-capture` !~ /flow-capture/ ) {
		$acc .= "No flow-capture process is running!\n";
		return $alertMajor;
	}
}

sub checkLockFiles
{
	foreach my $dir (values %logFileTempDirectory) {
		opendir(DIR, $dir);
		my @lockFiles = grep(/^flowage.*\.lck$/, readdir(DIR));
		closedir(DIR);

		foreach (@lockFiles) {
			open(IN, "$dir/$_") || next;
			my $pid = <IN>;
			chomp $pid;
			close(IN);

			next if (`ps h -p $pid` =~ /^\s*$pid\s/);

			$acc .= "Lock file $dir/$_ references an unknown pid $pid\n";
			$acc .= &correctFile("$dir/$_");
		}
	}
}

sub checkFlowageLog
{
	my $maxCount = 2;
	my %filePos;
	my $retCode = 0;

	open(IN, $stateLogFile);
	foreach (@logFiles) {
		chomp($filePos{$_} = <IN>);
		delete $filePos{$_} if ($filePos{$_} > -s $_);		# file has reset
	}

	foreach my $log (@logFiles) {
		print "reading $log\n";

		my (@lockMsgs, @bucketMsgs);
		open(IN, $log) || next;
		seek(IN, $filePos{$log}, 0);

		my $stillLocked = 0;
		my $stillBucketed = 0;
		my $allBucketed = 0;
		my @buffer;

		while ( <IN> ) {
			if (/could not grab lock file/) {
				push(@lockMsgs, $_);
				$stillLocked = 1;
			}

			if (/no-bucket flows/) {
				if (! / 0 no-bucket flows/) {
					push(@bucketMsgs, $_);
					if (/processed (\d+) flows.*, (\d+) localFlows, (\d+) no-bucket flows/) {
						$allBucketed = ($3 >= ($1 - $2));
						$stillBucketed = 1;
					}
				}
				else {
					undef $stillBucketed;
					undef $allBucketed;
				}
			}

			if (/reading/) {
				undef $stillLocked;
			}

			if (/start of flowage.pl/) {
				undef @buffer;
			}
			push(@buffer, $_);

			if (/quitting/) {		# BOMB OUT
				$acc .= $log . ":\n  " . join("  ", @buffer) . "\n";
				$retCode |= $alertMajor;
			}
		}


		if (@lockMsgs) {
			splice(@lockMsgs, $maxCount, (scalar @lockMsgs) - $maxCount * 2, "...\n")
				if (@lockMsgs > ($maxCount * 2));
			$acc .= $log . ":\n  " .  join("  ", @lockMsgs) . "\n";

			if ($stillLocked) {
				$acc .= &correctFile($logFileTempDirectory{$log} . '/*.lck');
				$retCode |= $alertMajor;
			}
			else {
				$acc .= "  The problem appears to have healed itself. No further action is necessary.\n\n";
				$retCode |= $alertMinor;
			}
		}

		if (@bucketMsgs) {
			splice(@bucketMsgs, $maxCount, (scalar @bucketMsgs) - $maxCount * 2, "...\n")
				if (@bucketMsgs > ($maxCount * 2));
			$acc .= $log . ":\n  " .  join("  ", @bucketMsgs) . "\n";

			if ($stillBucketed) {
				if ($allBucketed) {
					$acc .= &correctFile($logFileTempDirectory{$log} . '/flowage-buckets.bin');
					$retCode |= $alertMajor;
				}
				else {
					$acc .= "  The problem appears limited to a few devices. Check them for NTP problems.\n\n";
					$retCode |= $alertMinor;
				}
			}
			else {
				$acc .="  The problem appears to have healed itself. No further action is necessary.\n\n";
				$retCode |= $alertMinor;
			}
		}

		$filePos{$log} = tell(IN);
		close(IN);
	}

	open(OUT, '>' . $stateLogFile);
	foreach (@logFiles) {
		print OUT $filePos{$_}, "\n";
	}
	close(OUT);

	return $retCode;
}

sub checkStdout
{
	my $retCode = 0;

	foreach my $log (@logFiles) {
		my (@snmpMsgs);
		my $file = $logFileTempDirectory{$log} . '/stdout.txt';

		open(IN, $file);
		while ( <IN> ) {
			push(@snmpMsgs, $_) if (/respond to SNMP/);
		}
		close(IN);

		if (@snmpMsgs) {
			$acc .= $file . ":\n  " . join("  ", @snmpMsgs);
			$retCode |= $alertMinor;
		}
	}

	return $retCode;
}

sub correctFile
{
	return if (! $ATTEMPT_FIX);
	my $file = $_[0];

	my $acc = "  Corrective action: deleting $file\n";

	`rm -f $file`;

	if (! $?) {
		return $acc . "  ...Appears successfull. Fix should take effect immediately.\n\n";
	}
	else {
		return $acc . "  ...Error $?: $!\n\n";
	}
}


#!/usr/bin/perl -w
#
# git-deploy.pl - deploy a git repository to a master server
# then it deploys to production servers
# 

# libs {{{
use strict;
use POSIX;
use feature qw/say/;
use File::Basename;
use FindBin qw($RealBin);
use Getopt::Long qw(:config pass_through);
use Term::ANSIColor; 
use Term::ReadLine; # from libterm-readline-perl-perl
use FileHandle;
use Sys::Syslog qw/:standard :macros/;
use Sys::Hostname;
use Cwd qw/realpath/;
# for SSH control
use IPC::Open3;
use IO::Select;
use IO::Handle;
use threads ('exit' => 'threads_only');
use Thread::Queue;
use Data::Dumper;
no warnings 'closure';
# }}}


# {{{ config
my $rsync = "/usr/bin/rsync";
my $default_rsync_opts = "
	-rlptgoD
	--progress
	--stats
	--acls
	--human-readable
	--one-file-system
	--delay-updates
	--delete-delay
	--exclude='.git/'
	--exclude='*/lost+found/**'
	--exclude='*.LCK'
	--exclude='*.working'
	--exclude='*.pyo'
	--exclude='*.pyc'
";
my $hooksdir = '.hooks';
my $rsync_tun_port = 8731;
# }}}


# {{{ internal vars
my ($ssh, $sshtun);
my $repo;
my $sourcedir;
my $rsync_module;
my $rsync_password = "/etc/rsyncd.passwd";
my $rsync_user;
my $rsync_dir;
my $rsync_remote_path;
my $master;
my $servers;
my $config;
my $debug = 0;
my $quick = 0;
my $stage;
my $opt_dryrun = 0;
my $progress_i = 0;
my @progresschars = qw(| / - \\);
my $deploymode = 0;
my $mutu = 0;
my $minrev = 0;
my $before_cid = 'unknown_before';
my $after_cid = '';
my $deploy_tags;
# ssh
local (*SSHIN, *SSHOUT, *SSHERR); # Tunnel's standard IN/OUT/ERR 
my $sshio;
$| = 1;
# }}}


# {{{ Functions
#----------------- logging functions --------------------# {{{

my $me = basename($0);
my $logfile = "/tmp/".$me.".log";
my $logfh;

END {
	logclose();
}

sub loginit
{
	$logfile = shift;
	$debug = shift;
	if ($logfh)
	{
		$logfh->close();
		undef $logfh;
	}
	openlog($me, 'noeol,nofatal,pid', LOG_SYSLOG); # "syslog"
}

sub loginfo
{
	my $s = shift;
	print color 'bold cyan on_blue';
	print $s;
	print color 'reset';
	print $/;
	logdebug ("INFO::".$s.$/);
}

sub loginfo2
{
	my $s = shift;
	print color 'bold blue';
	print $s;
	print color 'reset';
	print $/;
	logdebug ("INFO::".$s.$/);
}

sub loginfo3
{
	my $s = shift;
	print color 'bold cyan';
	print $s;
	print color 'reset';
	print $/;
	logdebug ("INFO::".$s.$/);
}

sub logmsg
{
	my $s = shift;
	print $s;
	print color 'reset';
	print $/;
	logdebug ($s.$/);
}


sub logwarn
{
	my $s = shift;
	my $a = shift || "";
	print "\r";
	print color 'yellow on_red';

	format STDOUT = 
WARNING: @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<	@<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
         $s,                                    $a
.
	write;
	logdebug ("WARN::".$s.$/);
	print color 'reset';
}

sub logfatal
{
	print color 'bold yellow on_red';
	print "FATAL: ".join($/, @_);
	print color 'reset';
	print $/;
	logdebug ("FATAL::".join($/, @_).$/);
	exit 1;
}

sub logdebug
{
	my $msg = shift;
	syslog("debug", $msg);
	unless (defined $logfh)
	{
		chmod 0666, $logfile if (-e $logfile);
		$logfh = new FileHandle;
		unless ($logfh->open(">>$logfile"))
		{
			return warn "DEBUG", $msg;
		}
	}	

	print $logfh (strftime "%d/%m/%Y %H:%M:%S", localtime) . " :: $msg" if ($logfh);
	print "\r".strftime("%d/%m/%Y %H:%M:%S", localtime) . " :: $msg" if ($debug);
}

sub logclose
{
	if ($logfh)
	{
		logdebug "Closing log file\n";
		$logfh->close();
		undef $logfh;
	}
}

#----------------- end logging functions --------------------# }}}

sub Usage # {{{
{
	print "Usage: $0 [--debug]\n";
	print "\t--repo REPOSITORY     : \n";
	print "\t--stage STAGE         : \n";
	print "\t--... must be completed :o)\n";
	exit 11;
}
# }}}

sub sshcmd
{
	my $ssh = "/usr/bin/ssh -AC -o StrictHostKeyChecking=no -t #tunnel# ";

	my ($host, $port) = split/:/, $master;

	if (defined($port))
	{
		$ssh .= "-p $port ";
		$master = $host;
	}

	$ssh .= $rsync_user.'@'.$master;
	my $sshtun = $ssh." '
	while read CMD
	do
		if [ \"\$CMD\" = \"\" ]
		then
			echo EXIT; break;
		fi
		bash -c \"\$CMD\"
	done
	'";
	$ssh =~ s/#tunnel#//;
	return ($ssh, $sshtun);
}

sub sshtun # {{{ Start the SSH tunnel
{
	my $logprefix = shift || "";
	my $sshpid = 0;


	# Check that nothing is using the port needed by tunnel.
	my $tmp_rsync_tun_port = $rsync_tun_port;
	my $max_ports = 20;
	my $pid_port = 0;
	while ($tmp_rsync_tun_port < $rsync_tun_port + $max_ports) {
		$pid_port = `/usr/bin/lsof -ti :$tmp_rsync_tun_port`;
		if ($? > 0)
		{
			last;
		}
		else
		{
			my @pids = split(/\n/, $pid_port);
			for my $pidp (@pids)
			{
				chomp($pidp);
				$pidp = int($pidp);
				my ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,$atime,$mtime,$ctime,$blksize,$blocks) = stat("/proc/$pidp");
				if ((time - $mtime) > 3600)
				{
					logwarn("git-up deploy blocked", "Kill pid $pidp");
					kill 'TERM', $pidp;
				}
				logmsg("Port $tmp_rsync_tun_port already used by pid #$pidp, try ".++$tmp_rsync_tun_port);
			}
		}
	}
	if ($tmp_rsync_tun_port >= $rsync_tun_port + $max_ports)
	{
		logfatal("🔞 Too many simultaneous deployments, try later.");
	}
	$rsync_tun_port = $tmp_rsync_tun_port;

	($ssh, $sshtun) = sshcmd();

	$sshtun =~ s/#tunnel#/-L $rsync_tun_port:localhost:873/;
	loginfo2($logprefix."🏁 Starting secure tunnel : $rsync_user\@$master...");
	#logdebug($logprefix.$sshtun.$/);

	eval
	{
		$sshpid = open3(\*SSHIN, \*SSHOUT, \*SSHERR, $sshtun);
		$sshio = IO::Select->new(*SSHOUT, *SSHERR);
	};
	if ($@)
	{
		if ($@ =~ /^open3/)
		{
			logfatal("😓 Unable to start secured tunnel: $!\n$@");
		}
		else
		{
			logdebug("DEBUG SSH: ".$@);
		}
	}
	else
	{
		# wait for establishment
		loginfo2($logprefix."⏳ Waiting for connection...");
		my ($out, $err, $bytes) = sshrun("echo READY", 1, 10);

		if (defined($out))
		{
			logdebug("WAIT: " . $out);
		}
		else
		{
			foreach my $ret (split($/, $err))
			{
				if ($ret !~ /Pseudo-terminal will not be allocated because stdin is not a terminal./)
				{
					logwarn("[$master]", $ret);
				}
			}
			#$ret = ''; # false for next if ...
		}

		if (defined($out) && $out eq 'READY')
		{
			loginfo2($logprefix."🔥 connection ready.");
		}
		else
		{
			logfatal("😓 Unable to start secured vortex: " . $err);
			closesshtun();
		}
	}

	return $sshpid;
}
# }}}

sub closesshtun # {{{
{
	if (SSHIN->opened())
	{
		loginfo3("Close SSH.");
		print SSHIN $/;
		close(SSHIN);
		close(SSHOUT);
		close(SSHERR);
	}
}
# }}}

# Shorten to hostname
sub get_shorthost
{
	my $host = shift;
	return $host;
	if ($host !~ /^\d/)
	{
		$host =~ /(.+?)\./;
		return $1;
	}
	return $host;
}

sub stage_folder
{
	my $repo = shift || undef;
	my $stage = shift || undef;
	my $mutu = shift || 0;
	my $dest = shift || undef;
	my $folder = "";
	$folder .= "/$stage" if (defined($stage));
	if (defined($dest))
	{
		$folder .= "/$dest";
	}
	elsif (defined($repo) && $mutu)
	{
		$folder .= "/$repo";
	}
	return $folder;
}

# Main function to rsync files to 1 remote or many
sub rsyncto # {{{
{
	my $srcdir = shift;
	my $out = shift;
	my $host = shift;
	my $repo = shift || undef;
	my $stage = shift || undef;
	my $try = shift || 0;
	chomp($host);
	my $logprefix = colored(sprintf("%-35s", "🤖 ".get_shorthost($host)), 'bold magenta');
	my $max_try = 2;
	my $verbose = 0;

	sub put
	{
		my $log = shift;
		if (defined($out))
		{
			$out->enqueue(get_shorthost($host), $log);
		}
		else
		{
			print($logprefix.$log);
		}
	}

	$srcdir = realpath($srcdir);
	logfatal("Source dir '$srcdir' not found.") unless ($srcdir);

	if (-d $srcdir)
	{
		$srcdir .= "/";
	}

	# rsync loop
	my $cmd;
	my $rsync_dest = $rsync_module;
	my $rsync_opts = $default_rsync_opts;

	$rsync_dest .= stage_folder($repo, $stage, $mutu, $rsync_dir) if defined ($stage);

	if ($rsync_dest eq $rsync_module)
	{
		$rsync_opts =~ s/delay-updates/inplace/;
	}
    $rsync_opts .= " --password-file=$rsync_password";

	if (-e $srcdir.'.rsync_excludes')
	{
		$rsync_opts .= " --exclude-from=$srcdir.rsync_excludes ";
		$default_rsync_opts .= " --exclude-from=$srcdir.rsync_excludes ";
	}
	
	if (-e $srcdir.'.rsync_includes')
	{
		$rsync_opts .= " --include-from=$srcdir.rsync_includes ";
		$default_rsync_opts .= " --include-from=$srcdir.rsync_includes ";
	}
	
	if (-e $srcdir.'.rsync_files_from')
	{
		$rsync_opts .= " --files-from=$srcdir.rsync_files_from ";
		$default_rsync_opts .= " --files-from=$srcdir.rsync_files_from ";
	}
	
	if ($deploymode)
	{
		$cmd = "$rsync $rsync_opts $srcdir/ rsync://gitup\@$host/$rsync_dest/";
	}
	else
	{
		# compression only over internet, and not between slaves
		$rsync_opts .= ' --compress --compress-level=9 --old-compress --info=NAME';
		$verbose = 1;
		$cmd = "$rsync $rsync_opts $srcdir rsync://gitup\@localhost:$rsync_tun_port/$rsync_dest/";
	}

	put "RSYNC $srcdir TO ".$host."::$rsync_dest $/" if ($debug);
	put "$cmd\n" if ($debug);

	my $rsync_pid = open(RSYNC, "$cmd 2>&1 3>&1 |");
	unless ($rsync_pid)
	{
		warn "ERROR rsync pid = $rsync_pid\n";
	}

	my $numfiles = 0;
	my $n = 0;
	my $stat_files_transferred = 0;
	my $stat_files_deleted = 0;
	my $stat_total_file_size = 0;
	my $stat_total_tr_file_size = 0;
	my $daemon_excluded = 0;
	while (<RSYNC>)
	{
		put ("DEBUG: ".$_) if ($debug);
		# don't display all errors
		if (/^(rsync:? \w+:) ?(.+)/)
		{
			my ($type, $msg) = ($1, $2);
			next if ($msg =~ /(to connect to localhost)|(error in socket IO )/);

			if ($msg =~ /errors selecting input\/output files, dirs \(code 3\)/)
			{
				$daemon_excluded++;
				next;
			}

			if ($daemon_excluded and $msg =~ /(some files could not be transferred)|(connection unexpectedly closed)|(error in rsync protocol data stream)/)
			{
				next;
			}
			put "\r";
			put ($daemon_excluded." [".$type."] ".$msg);
			put "\n";
		}

		elsif (/^skipping daemon-excluded /)
		{
			$daemon_excluded++;
		}

		# Display first message
		elsif (/^building file list/)
		{
			#put "\r";
			#put("Syncing ".($prod ? 'prod' : 'preprod')."/$sync/ ...\n");
		}

		elsif (/(\d+) files to consider/)
		{
			$numfiles = $1;
		}

		elsif (/Number of files: [0-9,]+ \(reg: ([0-9,]+), dir: [0-9,]+, link: [0-9,]+\)/)
		{
			$numfiles = $1;
			$numfiles =~ s/,//g;
		}

		# Fetch stats
		elsif (/Number of (regular )?files transferred: (\d+)/)
		{
			$stat_files_transferred = $2;
		}
		# Rsync 3.1
		elsif (/Number of deleted files: \d+ \(reg: (\d+), dir: \d+\)/)
		{
			$stat_files_deleted = $1;
		}

		# Total file size: 21.96M bytes
		# Total transferred file size: 0 bytes
		#
		elsif (/Total file size: (\d+\.?\d*\w*) bytes/)
		{
			$stat_total_file_size = $1
		}
		elsif (/Total transferred file size: (\d+\.?\d*\w*) bytes/)
		{
			$stat_total_tr_file_size = $1
		}

		# updating/deleting a file or directory
		elsif (/^(deleting )?(\w+?\/.+)/)
		{
			my $deleted = 0;
			if (/\s*deleting\s+/)
			{
				$stat_files_deleted += 1;
				$deleted++;
			}
			$n++;
			my $percent = "?";
			if ($progress_i >= $#progresschars)
			{
				$progress_i = 0;
			}
			else
			{
				$progress_i++;
			}
			my $s = $progresschars[$progress_i];
			
			if ($n > 0 and $numfiles > 0)
			{
				$percent = sprintf("%.02f", $n/$numfiles*100);
			}
			if ($verbose) {
				my $file = $_;
				chomp($file);
				my $prefix = "UPDATED";
				if ($deleted) {
					$prefix = "DELETED";
					$file =~ s/^deleting //;
				}
				put "$prefix $percent% : $file\n" if ($file =~ /[^\/]$/);
			} else {
				put(sprintf "\r%s%s %d/%d [%d%%]" . " "x40 . "\r", $logprefix, $s, $n, $numfiles, $percent);
			}
		}

		elsif (/xfe?r#\d+, to-che?c?k=/)
		{
			next;
		}

		elsif (/^(cannot delete non-empty directory|Number|Literal|Matched|File list|Total bytes|sent |total size)|file |xfr#/)
		{
			next;
		}

		#else
		#{
		#	put;
		#}
	}
	put "\r";

	close(RSYNC);
	my $r = $?;
	waitpid($rsync_pid, 0);
	put("RSYNC RC = $r\n") if ($debug);

	# 23 = "Skipping any contents from this failed directory"
	if ($r == 0 or ($daemon_excluded and ($r == 5888 or $r == 3072)))
	{
		put("│ Transfered: ".
		($stat_files_transferred > 0 ? colored($stat_files_transferred, 'bold green') : $stat_files_transferred).
		" │ Deleted: ".
		($stat_files_deleted > 0 ? colored($stat_files_deleted, 'bold red') : $stat_files_deleted).
		" │ Total: $numfiles │ Size: $stat_total_tr_file_size/$stat_total_file_size".
		($daemon_excluded ? " (some were excluded) │" : " │").
		$/);
		$r = 0;
	}
	elsif($r == 3072)
	{
		put ("Check that rsyncd is started on $host$/");
		put("Need destination folder: $host $rsync_module\n");
	}
	elsif($r == 2560 && $try < $max_try)
	{
		#rsync: failed to connect to localhost: Connection refused (111)
		unless($deploymode)
		{
			put("redo\n") if ($debug);
			$try ++;
			sleep(1);
			return rsyncto($srcdir, $out, $host, $repo, $stage, $try);
		}
	}
	elsif($r == 5120)
	{
		put("CANCELED\n");
	}
	else
	{
		put($logprefix."rsync error code try=$try: $r\n");
	}

	# bug ? Wait that rsync has really closed the connection
	#sleep(1);

	return !$r;
}
# }}}


sub hook
{
	my $hooktype = shift;
	my $hook = "$hooksdir/$hooktype-deploy";
    return if ($quick);
	
	my $cwd = getcwd;
	chdir ($sourcedir) or die "$!: ".$sourcedir;

	logdebug ("Run hook $sourcedir/$hook if exists$/");
	if (-x $hook)
	{
		loginfo3 "🗡️ Execute $hooktype-deploy hook ...";
		if (system($hook, $stage, $repo, $before_cid, $after_cid))
		{
			logfatal("💢 Hook '$hooktype' FAILED: exitcode=$? ($!)");
		}
	}

	chdir($cwd);
}

sub custom_hooks
{
	my $hooktype = shift;
	if ($deploy_tags && !$quick) {
		foreach my $tag (split(/[#,]/, $deploy_tags)) {
			next unless $tag;
			hook($hooktype."-".$tag);
		}
	}
}


# so usefull ...
sub get_first_defined
{
	foreach my $var (@_)
	{
		return $var if (defined($var));
	}
	return undef;
}


# Guess remote path by parsing rsyncd config
sub get_remote_path
{
	return $rsync_remote_path if (defined($rsync_remote_path));
	
	my ($out, $err, $bytes) = sshrun("grep -A 20 -F \"[$rsync_module]\" /etc/rsyncd.conf | grep '^[[:space:]]*path =' | head -1");
	if (defined($out))
	{
		$out =~ /^\s*path\s*=\s*(.+)$/;
		$rsync_remote_path = $1;
		logdebug("Remote path: $rsync_remote_path");
	}
	else
	{
		logfatal("💢 Unable to found remote path for [$rsync_module] from /etc/rsyncd.conf");
	}
	return $rsync_remote_path;
}


# Rsync myself to master
sub check_myself
{
	loginfo3("🗽 Check myself ...");

	get_remote_path();

	my $rsyncret = rsyncto($0, undef, $master, undef, undef);

	unless ($rsyncret)
	{
		logfatal("💢 Unable to upload myself :(");
	}
}

# convenient function
sub sshrun
{
	my $cmd = shift;
	my $oneline = shift || 1;
	my $timeout = shift || 1;
	my @ready;
	my $out;
	my $err;
	my $bytes = 0;

	if (SSHIN->opened())
	{
		print SSHIN "$cmd$/";
	}
	else
	{
		logwarn("SSH", "SSH stdin is closed");
	}

	while (@ready = $sshio->can_read($timeout))
	{
		my $chomped = 0;
		my $b = 0;
		foreach my $fh (@ready)
		{
			my $read;
			$b += sysread($fh, $read, 16);
			
			$bytes += $b;

			$chomped = chomp($read) if ($oneline);

			if ($fh eq *SSHOUT)
			{
				$out .= $read;
			}
			elsif ($fh eq *SSHERR)
			{
				$err .= $read;
			}
		}
		if ($out && $chomped && $oneline)
		{
			last;
		}
		if ($b == 0)
		{
			last;
		}

	}
	return ($out, $err, $bytes);
}
# }}}


#
# Main {{{
#
GetOptions (
	"dry-run" => \$opt_dryrun,
	"help" => \&Usage,
	"debug" => \$debug,
	"quick" => \$quick,
	"deploy" => \$deploymode,
	"mutu" => \$mutu,
	"repo=s" => \$repo,
	"stage=s" => \$stage,
	"source-dir=s" => \$sourcedir,
	"rsync-module=s" => \$rsync_module,
	"rsync-password=s" => \$rsync_password,
	"rsync-user=s" => \$rsync_user,
	"rsync-dir=s" => \$rsync_dir,
	"master=s" => \$master,
	"servers=s" => \$servers,
	"before=s" => \$before_cid,
	"after=s" => \$after_cid,
	"tags=s" => \$deploy_tags
);

Usage unless (defined($repo) && defined($stage));

open STDERR, '>&STDOUT';
loginit($logfile, $debug);

# Sanity checks ...
foreach my $var2check ($stage, $sourcedir, $rsync_module, $rsync_user)
{
	unless(defined($var2check) && length($var2check) > 0)
	{
		logfatal("💢 Project '$repo' is not yet configured to be deployed.");
	}
}


# debug:
if ($opt_dryrun)
{
	$default_rsync_opts = "--dry-run $default_rsync_opts";
}
#if ($debug)
#{
#	$default_rsync_opts = "--verbose $default_rsync_opts";
#}

# Flatten rsync opts
$default_rsync_opts =~ s/\n\t?/ /g;


# 
# DEPLOY MODE (on remote master)
#
if ($deploymode)
{
	my @pids;
	my @hosts;
	if ($servers)
	{
		@hosts = split(",", $servers);
	}

	hook('mid');
	custom_hooks('mid');

	for (my $i=0; $i<scalar(@hosts); $i++)
	{
		$hosts[$i] =~ /(.+?)\./;
		# Remove myself
		if (($1 and hostname =~ /^$1\.?/) or (hostname eq $hosts[$i]))
		{
			$hosts[$i] = undef;
		}
	}
	@hosts = grep defined, @hosts; # removes undef

	if (scalar(@hosts) > 0)
	{
		loginfo3 "✈️  Deploy to ".scalar(@hosts)." servers ...";

		# declaration du thread
		my @threads;
		my $thr_out = Thread::Queue->new();
		sub thread_sync
		{
			my ($logprefix, $host) = @_;
			unless (rsyncto($sourcedir, $thr_out, $host, $repo, $stage))
			{
				$thr_out->enqueue($host, "FAILED");
			}
		}

		# boucle sur les serveurs
		foreach my $host (@hosts)
		{
			my $logprefix = "🤖 ".get_shorthost($host)." ";
			# 
			# Method thread
			#
			push @threads, threads->create("thread_sync", $logprefix, $host);
		}

		# Affichage => SSHOUT
		my $display_th = threads->create(sub { 
			my @hosts = @_;
			my ($host, $log);
			print "HOSTS=".join(",", @hosts)."\n";
			do
			{
				$host = $thr_out->dequeue();
				$log = $thr_out->dequeue();
				print "HOST=$host|LOG=$log\n" if ($host);
			}
			while (defined($host) && defined($log));
		}, @hosts);

		foreach my $thr (@threads)
		{
			$thr->join();
		}
		$thr_out->enqueue(undef, undef);
		$display_th->join();
	}
	hook('post');
	custom_hooks('post');
}


#
# SOURCE => MASTER
#
else
{
	$SIG{INT} = \&closesshtun;
	$SIG{TERM} = \&closesshtun;
	$SIG{QUIT} = \&closesshtun;
	$SIG{PIPE} = \&closesshtun;

	# Tunnel SSH
	my $sshpid = sshtun();
	my $rsyncok;

	# if not connected
	unless ($sshpid)
	{
		logfatal("💢 Unable to start SSH vortex");
	}

	get_remote_path();
	check_myself();
	
	loginfo3("🛫 Sync to $master...");

	# start sync to master
	$rsyncok = rsyncto($sourcedir, undef, $master, $repo, $stage);
	my @failedsync;

	# if sync passed, sync to slaves
	#if ($rsyncok && !defined($servers))
	#{
	#	logdebug("No slave servers found.");
	#}
	#elsif ($rsyncok)
	if ($rsyncok)
	{
		my %hdata;

		unless (defined($servers))
		{
			$servers = "";
		}
		# Change sourcedir to remote source dir !
		my @args;
		push @args, "--deploy";
		push @args, "--repo=$repo";
		push @args, "--stage=$stage";
		push @args, "--source-dir=".get_remote_path().stage_folder($repo, $stage, $mutu, $rsync_dir);
		push @args, "--rsync-module=$rsync_module";
        #push @args, "--rsync-password=$rsync_password";
		push @args, "--rsync-user=$rsync_user";
		push @args, "--rsync-dir=$rsync_dir" if defined($rsync_dir);
		push @args, "--servers=$servers";
		push @args, "--before=$before_cid";
		push @args, "--after=$after_cid";
        #push @args, "--debug" if ($debug);
		push @args, "--mutu" if ($mutu);
		push @args, "--tags=$deploy_tags" if defined($deploy_tags);

		my $cmd = "perl ".get_remote_path()."/$me ".join(" ", @args)."; echo EZSYNCDONE";

		logdebug("Exec $cmd\n");
		print SSHIN $cmd.$/;
		while (<SSHOUT>)
		{
			if (/HOST=(.+?)\|LOG=(.+)/)
			{
				my $host = $1;
				my $log = $2;
				chomp($log);
				if ($log =~ /FAILED/)
				{
					$host = get_shorthost($host);
					push @failedsync, $host;
					logwarn("[$host]", $log);
				}
				elsif ($log !~ /\[(\d+)\%\]/)
				{
					$log =~ s/\r//g;
					print colored(sprintf("%-32s", "🤖 $host"), 'bold magenta')."$log$/" unless ($log eq "");
				}
			}
			elsif (/HOSTS=(.+)/)
			{
				foreach my $h (split(/,/, $1))
				{
					$h = get_shorthost($h);
					$hdata{$h} = 0;
				}
			}
			# from "echo" in $cmd
			elsif (/EZSYNCDONE$/)
			{
				print SSHIN $/;
				last;
			}
			else
			{
				# log* from script
				print $_ if ($_ ne $/);
			}
		}
	}
	else
	{
		warn "Error rsyncto()$/";
		print SSHIN $/;
	}
	

	print SSHIN $/ if (*SSHIN);
	#closesshtun;

	# Wait for SSH
	logdebug("Waiting $sshpid\n");
	waitpid($sshpid, 0);
    $quick = 0;

	# An error occured on at least one slave
	if ($#failedsync >= 0)
	{
		my $msg = "Failed to sync on ".scalar(@failedsync)." servers: ".(join(",", @failedsync));
		$msg .= "\\nProject=$repo Stage=".($stage ? "yes" : "no");
		logfatal($msg);
	}
	elsif ($rsyncok)
	{
		hook('report');
		loginfo("🛬 Sync Successful");
		exit 0;
	}
	else
	{
		logfatal("💢 Failed to sync on master.");
	}
}

# }}}


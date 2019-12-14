#!/usr/bin/perl
use Cwd;
use File::Basename;
use File::Find;
use File::stat qw(:FIELDS);
use File::Spec::Functions;
use Sys::Hostname;
use DirHandle;
use Time::localtime;
use Fcntl;
use Tie::File;
use Net::FTP;
use Data::Dumper;

my $WAIT_TIME = 10800; # 3 hours

my @FN=split("/",$0);
my $SPID="/var/run/".$FN[-1];

my $script_name= basename($0);

my $cfg_file = "/usr/local/etc/backup.conf";
my $ve_id = "";
my $ve_root = "";

if ($ARGV[0]) { $cfg_file = $ARGV[0]; }
if ($ARGV[1]) { $ve_id = $ARGV[1]; }

eval {
#set timeout for script work
$SIG{ALRM} = sub { die "Maximum worktime $WAIT_TIME sec reached!\n" };

alarm $WAIT_TIME;

if (! -e $cfg_file) { die ("File $cfg_file not found. Die...\n"); }

require $cfg_file;

my $filename = "";
my $filefrom = "";


my $tm = localtime;
($year,$month,$day,$wday) = ($tm->year+1900,$tm->mon+1,$tm->mday,$tm->wday);
my $date = sprintf("%04d",$year).sprintf("%02d",$month).sprintf("%02d",$day);
my $ttop = time;
my $empty = 0;

@dirlist = ();
@exclist = ();
*name = *File::Find::name;

if (!($cfg_tmp_dir ne "" and $cfg_hostname ne "" and $cfg_ftp_hostname ne "" 
    and $cfg_ftp_username ne "" and $cfg_ftp_password ne "" and $cfg_ftp_path 
    ne "" and $cfg_full_day ne "" and $cfg_del_files ne ""))  {
	die ("Not set configuration variables! Die...\n");
    }

if ($cfg_admin_email eq "" or $cfg_from_email eq "") { $cfg_admin_email = "root"; $cfg_from_email = $cfg_admin_email; }
if (!$cfg_use_ftp) { $cfg_use_ftp = "no"; }
if (!$cfg_use_smb) { $cfg_use_smb = "no"; }

if (!$tar_opts) { $tar_opts="--no-recursion"; }

if (IsNotRun($SPID)) { Add_PID($SPID); }
    else { die ("Warning!!! backup.pl already runnning!\n"); }

if (!$cfg_dirlist_file) { $cfg_dirlist_file ="/usr/local/etc/dirlist.conf"; }
if (!$cfg_exclist_file) { $cfg_exclist_file ="/usr/local/etc/exclist.conf"; }

if (!$cfg_mysql_dump) { $cfg_mysql_dump = "mysqldump"; }

#for vz container
if ($ve_id) {
    $cfg_exclist_file=~s/.conf//;
    $cfg_exclist_path=$cfg_exclist_file;
    #if found personal rule - use it
    if (-e $cfg_exclist_path."-$ve_id.conf") { $cfg_exclist_file=$cfg_exclist_path."-$ve_id.conf"; }
	else {
	#use common rule
        if (-e $cfg_exclist_path."-vz.conf") { $cfg_exclist_file=$cfg_exclist_path."-vz.conf"; }
	    else {
	    #if personal and common file not found - use default
	    $cfg_exclist_file=$cfg_exclist_path.".conf";
	    }
	}
    $ve_root = "/vz/root/$ve_id/";
    $cfg_hostname=$ve_id;
    }

if (-e $cfg_dirlist_file) {
    open (FD,"<",$cfg_dirlist_file);
    while (<FD>) {
	chomp;
        push(@dirlist,$_);
	}
    close(FD);
    die ("Warning!!! no listing dir for backup. Exit.\n") if ($#dirlist eq "-1");
    }
    else { die ("File $cfg_dirlist_file not found! die...\n"); }

if (-e $cfg_exclist_file) {
    open (FD1,"<",$cfg_exclist_file);
    while (<FD1>) {
        chomp;
        my $ex=$_;
        if ($ve_id) {
            if ($ex=~/\//) {
        	if ($ex=~/\^(.*)/) {$ex="^".$ve_root.$1; } else { $ex=$ve_root.$ex; }
        	$ex=~s/\/\//\//g; 
        	}
            }
	push(@exclist,$ex);
	}
    close(FD1);
    }

#dirlist ignored if backup vz container
#Left for compatibility
if ($ve_id) { @dirlist = ( "./" ); }

my $fullbackup = ($cfg_full_day eq $wday);

if ((!$fullbackup) and (! -e "$cfg_status_dir/$cfg_hostname-back_file_size$ve_id.list")) { $fullbackup=1; }

if (!$fullbackup) {
    open (FHD,">","$cfg_status_dir/$cfg_hostname-back_file_diff$ve_id.list");
    sub process_file_diff {
	if ($#exclist eq "-1") {
	    if (-f) {
		$info = stat($name);
		print FHD $info->mtime."	".$info->size."	".$name."\n";
	    }
	}else{
	    if (-f) {
		$exists = 0;
		$info = stat($name);
		for ($i = 0; $i < @exclist; $i++) {
		    $ii = $exclist[$i];
		    $exists = ($exists or ($name =~ /$ii/));
		}
		if (!$exists) {
		    print FHD $info->mtime."	".$info->size."	".$name."\n";
		}
	    }
	}
    }
    if ($ve_root) { find(\&process_file_diff, $ve_root); }
	else {
	foreach $idir (@dirlist) {
	    find(\&process_file_diff, $idir);
	    }
	}
    close(FHD);
    system("diff -f $cfg_status_dir/$cfg_hostname-back_file_size$ve_id.list $cfg_status_dir/$cfg_hostname-back_file_diff$ve_id.list | grep / > $cfg_status_dir/$cfg_hostname-file$ve_id.diff");
    tie @ddiff, Tie::File, "$cfg_status_dir/$cfg_hostname-file$ve_id.diff";
    if ($#ddiff ne "-1") {
        open(FDD,">","$cfg_status_dir/$cfg_hostname-back_diff$ve_id.list");
	foreach $mdiff (@ddiff) {
	    ($a,$b,$c) = split /\t/,$mdiff;
	    $a = "";
	    $b = "";
	    print FDD $c."\n";
	}
	close (FDD);
        $filename = "$cfg_tmp_dir/$cfg_hostname-inc-$wday.tar.gz";
	$filefrom = "$cfg_status_dir/$cfg_hostname-back_diff$ve_id.list";
	}
	else { $empty=1; }
    }
    else{
    unlink <$cfg_tmp_dir/$cfg_hostname*>;
    open (FH1,">","$cfg_status_dir/$cfg_hostname-back_file_size$ve_id.list");
    open (FH2,">","$cfg_status_dir/$cfg_hostname-back_file$ve_id.list");
    sub process_file {
	if ($#exclist eq "-1") {
	    if (-f) {
		$info = stat($name);
		print FH1 $info->mtime."	".$info->size."	".$name."\n";
		print FH2 $name."\n";
	    }
	}else{
	    if (-f) {
		$exists = 0;
		for ($i = 0; $i < @exclist; $i++) {
		    $ii = $exclist[$i];
		    $exists = ($exists or ($name =~ /$ii/));
		}
		if (!$exists) {
		    $info = stat($name);
		    print FH1 $info->mtime."	".$info->size."	".$name."\n";
		    print FH2 $name."\n";
		}
	    }
	}
    }
    if ($ve_root) { find(\&process_file, $ve_root); }
	else {
        foreach $idir (@dirlist) {
		find(\&process_file, $idir);
	    }
	}
    close(FH1);
    close(FH2);
    $filename = "$cfg_tmp_dir/$cfg_hostname-full-$date.tar.gz";
    $filefrom = "$cfg_status_dir/$cfg_hostname-back_file$ve_id.list";
    }
if ($empty eq 0) {
my $ret=`tar $tar_opts -czPf $filename --files-from=$filefrom`;
$tbot = time - $ttop;
open(FHR,">","$cfg_status_dir/report$ve_id.txt");
$minfo = stat($filename);
print FHR sprintf("%-45s %10s %20s\n",basename($filename),$tbot,$minfo->size);
close(FHR);
}

my @mysql_backup_files = ();
my @mongo_backup_files = ();
my @pgsql_backup_files = ();

if ($cfg_mysql_backup eq "yes") {
    if ($cfg_mysql_db[0]=~/all/i) {
	my $run_cmd="echo 'show databases;' | mysql -u \"$cfg_mysql_user\" -h \"$cfg_mysql_host\" -s --password=\"$cfg_mysql_pass\"";
	if ($cfg_mysql_host!~/[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/) {
		$run_cmd = "echo 'show databases;' | mysql -u \"$cfg_mysql_user\" -S \"$cfg_mysql_host\" -s --password=\"$cfg_mysql_pass\"";
		}
	@cfg_mysql_db = `$run_cmd`;
        chomp(@cfg_mysql_db);
	}
    $mysql_path = $0;
    $mysql_path=~ s/$script_name$/mysqld_backup/;

    $mysql_path=$mysql_path."2" if ($cfg_mysql_dump eq "mysqldump");

    foreach my $db (@cfg_mysql_db) {
	next if ($db=~/^information_schema$/);
        $ttop = time;
	my $lang='';
	if ($cfg_mysql_locale) { $lang="LANG=".$cfg_mysql_locale." "; }
	$fname="$cfg_tmp_dir/$cfg_hostname-mysql-$date-$db".".tgz";
	$ret=`$lang$mysql_path \"$cfg_mysql_host\" \"$cfg_mysql_user\" \"$cfg_mysql_pass\" \"$db\" \"$cfg_tmp_dir/$cfg_hostname-mysql-$date\"`;
	push (@mysql_backup_files,$fname) if ($? eq 0);
        $tbot = time - $ttop;
        open(FHR,">>","$cfg_status_dir/report$ve_id.txt");
        $minfo = stat($fname);
        print FHR sprintf("%-45s %10s %20s\n",$fname,$tbot,$minfo->size);
        close(FHR);
	}
    }

if ($cfg_mongo_backup eq "yes") {
        $mongo_path = $0;
	$mongo_path=~ s/$script_name$/mongo_backup/;
        if ($cfg_mysql_db[0]=~/all/i) {
	        $ttop = time;
		$fname="$cfg_tmp_dir/$cfg_hostname-mongo-$date-all".".tgz";
		my $ret=`$mongo_path \"$cfg_mongo_host\" \"$cfg_mongo_user\" \"$cfg_mongo_pass\" \"all\" \"$cfg_tmp_dir/$cfg_hostname-mongo-$date\"`;
		push (@mongo_backup_files,$fname) if ($? eq 0);
	        $tbot = time - $ttop;
	        open(FHR,">>","$cfg_status_dir/report$ve_id.txt");
	        $minfo = stat($fname);
	        print FHR sprintf("%-45s %10s %20s\n",$fname,$tbot,$minfo->size);
	        close(FHR);
		} else {
	        foreach my $db (@cfg_mongo_db) {
		        $ttop = time;
			$fname="$cfg_tmp_dir/$cfg_hostname-mongo-$date-$db".".tgz";
			my $ret=`$mongo_path \"$cfg_mongo_host\" \"$cfg_mongo_user\" \"$cfg_mongo_pass\" \"$db\" \"$cfg_tmp_dir/$cfg_hostname-mongo-$date\"`;
			push (@mongo_backup_files,$fname) if ($? eq 0);
		        $tbot = time - $ttop;
		        open(FHR,">>","$cfg_status_dir/report$ve_id.txt");
		        $minfo = stat($fname);
		        print FHR sprintf("%-45s %10s %20s\n",$fname,$tbot,$minfo->size);
		        close(FHR);
		}
	}
    }

if ($cfg_pgsql_backup eq "yes") {
    $cfg_pgsql_su = "no" if (!$cfg_pgsql_su);
    open(PGP,">","/root/.pgpass");
    print PGP "$cfg_pgsql_host:5432:*:$cfg_pgsql_user:$cfg_pgsql_pass";
    close(PGP);
    chmod 0400,"/root/.pgpass";
    chown 0,0,"/root/.pgpass";
    if ($cfg_pgsql_dump eq "pg_dump") {
        $pgsql_path = $0;
	$pgsql_path=~ s/$script_name$/postgres_listdb/;
        if ($cfg_pgsql_db[0]=~/all/i) {
		@cfg_pgsql_db = `$lang$pgsql_path \"$cfg_pgsql_su\" \"$cfg_pgsql_host\" \"$cfg_pgsql_user\"`;
		chomp(@cfg_pgsql_db);
		}
        $pgsql_path = $0;
	$pgsql_path=~ s/$script_name$/postgres_backup1/;
        foreach my $db (@cfg_pgsql_db) {
		next if (!$db);
		my $lang='';
	        $ttop = time;
		if ($cfg_pgsql_locale) { $lang="LANG=".$cfg_pgsql_locale." "; }
		$fname = "$cfg_tmp_dir/$cfg_hostname-pgsql-$date-$db".".tgz";
		$ret=`$lang$pgsql_path \"$db\" \"$cfg_tmp_dir/$cfg_hostname-pgsql-$date\" \"$cfg_pgsql_su\" \"$cfg_pgsql_host\" \"$cfg_pgsql_user\"`;
		push (@pgsql_backup_files,$fname) if ($? eq 0);
	        $tbot = time - $ttop;
		open(FHR,">>","$cfg_status_dir/report$ve_id.txt");
	        $minfo = stat($fname);
		print FHR sprintf("%-45s %10s %20s\n",$fname,$tbot,$minfo->size);
	        close(FHR);
	    }
        } else {
        $pgsql_path = $0;
	$pgsql_path=~ s/$script_name$/postgres_backup2/;
	my $lang='';
        $ttop = time;
	if ($cfg_pgsql_locale) { $lang="LANG=".$cfg_pgsql_locale." "; }
	$fname = "$cfg_tmp_dir/$cfg_hostname-pgsql-$date-$cfg_hostname".".tgz";
	$ret=`$lang$pgsql_path \"$cfg_tmp_dir/$cfg_hostname-pgsql-$date\" \"$cfg_pgsql_su\"  \"$cfg_pgsql_user\" \"$cfg_pgsql_host\" \"$cfg_hostname\"`;
	push (@pgsql_backup_files,$fname) if ($? eq 0);
        $tbot = time - $ttop;
	open(FHR,">>","$cfg_status_dir/report$ve_id.txt");
        $minfo = stat($fname);
	print FHR sprintf("%-45s %10s %20s\n",$fname,$tbot,$minfo->size);
        close(FHR);
	}
    unlink "/root/.pgpass";
    }

if ($cfg_use_ftp ne "no") {

    $ftp = Net::FTP->new($cfg_ftp_hostname,Timeout => 30,Passive => $cfg_ftp_mode);

    die("Can't connect to $cfg_ftp_hostname !\n") if (!$ftp);
    die ("Couldn't authenticate, even with explicit username and password.\n") if (!$ftp->login($cfg_ftp_username,$cfg_ftp_password));

    if (!$ftp->cwd($cfg_ftp_path)) {
	if ($ftp->mkdir ($cfg_ftp_path,1)) { $ftp->cwd($cfg_ftp_path); }
	    else { die ("Can't create directory $cfg_ftp_path at $cfg_ftp_hostname! Die...\n"); }
	}
    $ftp->binary();
    if ($filename) {
        die ("Can't put backup $filename to $cfg_ftp_hostname!\n") if (!$ftp->put($filename));
	}
    foreach $db (@mysql_backup_files) {
    die ("Can't put $db to $cfg_ftp_hostname!\n") if (!$ftp->put("$db"));
    }
    foreach $db (@pgsql_backup_files) {
    die ("Can't put $db to $cfg_ftp_hostname!\n") if (!$ftp->put("$db"));
    }

    $ftp->put("$cfg_status_dir/report$ve_id.txt");
    $ftp->quit();
    };

if ($cfg_use_smb ne "no") {
    my $smb_path=$0;
    $smb_path=~ s/$script_name$/smb_copy/;
    my $ret=`$smb_path \"$cfg_smb_hostname\" \"$cfg_smb_username\" \"$cfg_smb_password\" \"$cfg_smb_share\" \"$cfg_smb_path\" \"$filename\"`;
    my $res = $?;
    die "$ret" if ($res);
    foreach $db (@mysql_backup_files) {
        `$smb_path \"$cfg_smb_hostname\" \"$cfg_smb_username\" \"$cfg_smb_password\" \"$cfg_smb_share\" \"$cfg_smb_path\" \"$db\"`;
	$res = $?;
        die "$ret" if ($res);
	}
    foreach $db (@mongo_backup_files) {
        die ("Can't put $db to $cfg_ftp_hostname!\n") if (!$ftp->put("$db"));
	}
    foreach $db (@pgsql_backup_files) {
        `$smb_path \"$cfg_smb_hostname\" \"$cfg_smb_username\" \"$cfg_smb_password\" \"$cfg_smb_share\" \"$cfg_smb_path\" \"$db\"`;
	$res = $?;
        die "$ret" if ($res);
	}
    }

unlink <$cfg_tmp_dir/$cfg_hostname*> if ($cfg_del_files eq "yes");
$SIG{ALRM} = 'DEFAULT';
};

if ($@) { abort($cfg_admin_email,$cfg_from_email,"Script aborted. Error: $@\n",$SPID); };

if (IsMyPID($SPID)) { Remove_PID($SPID); };

exit 0;

#---------------------------------------------------------------------------------------------------------

sub sendEmail
{
my ($to, $from, $subject, $message) = @_;
my $sendmail = '/usr/lib/sendmail';
open(MAIL, "|$sendmail -oi -t");
print MAIL "From: $from\n";
print MAIL "To: $to\n";
print MAIL "Subject: $subject\n\n";
print MAIL "$message\n";
close(MAIL);
}

#---------------------------------------------------------------------------------------------------------

sub abort {
my ($to,$from,$message, $pid) = @_;
sendEmail ($to,$from,"Backup error at $cfg_hostname!",$message);
if (IsMyPID($pid)) { Remove_PID($pid); };
die ($message);
}

#---------------------------------------------------------------------------------------------------------

sub IsNotRun {
my $pname = shift;
my $lockfile = $pname.".pid";
if (! -e $lockfile) { return 1; }
open (FF,"<$lockfile") or die "can't open file $lockfile: $!";
my $lockid = <FF>;
close(FF);
if ($lockid eq $$) { return 1; }
my $process_count = `ps axwu | awk '\{ print \$2 \}' | grep $lockid | wc -l`;
if ($process_count lt 1) { unlink $lockfile; return 1; }
return 0;
}

#---------------------------------------------------------------------------------------------------------

sub IsMyPID {
my $pname = shift;
my $lockfile = $pname.".pid";
if (! -e $lockfile) { return 0; }
open (FF,"<$lockfile") or die "can't open file $lockfile: $!";
my $lockid = <FF>;
close(FF);
if ($lockid eq $$) { return 1; }
return 0;
}

#---------------------------------------------------------------------------------------------------------

sub Add_PID {
my $pname = shift;
my $lockfile = $pname.".pid";
open (FF,">$lockfile") or die "can't open file $lockfile: $!";
flock(FF,2) or die "can't flock $lockfile: $!";
print FF $$;
close(FF);
return 1;
}

#---------------------------------------------------------------------------------------------------------

sub Remove_PID {
my $pname = shift;
my $lockfile = $pname.".pid";
if (! -e $lockfile) { return 1; }
unlink $lockfile or return 0;
return 1;
}


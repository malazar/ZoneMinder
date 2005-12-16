#!/usr/bin/perl -wT
#
# ==========================================================================
#
# ZoneMinder Package Control Script, $Date$, $Revision$
# Copyright (C) 2003, 2004, 2005  Philip Coombes
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
#
# ==========================================================================
#
# This script is used to start and stop the ZoneMinder package primarily to
# allow command line control for automatic restart on reboot (see zm script)
#
use strict;
use bytes;

# ==========================================================================
#
# These are the elements you can edit to suit your installation
#
# ==========================================================================

use constant DBG_LEVEL => 0; # 0 is errors, warnings and info only, > 0 for debug

# ==========================================================================
#
# Don't change anything below here
#
# ==========================================================================

use ZoneMinder;
use DBI;
use POSIX;
use Time::HiRes qw/gettimeofday/;

use constant LOG_FILE => ZoneMinder::ZM_PATH_LOGS.'/zmpkg.log';

# Detaint our environment
$ENV{PATH}  = '/bin:/usr/bin';
$ENV{SHELL} = '/bin/sh' if exists $ENV{SHELL};
delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};

my $command = $ARGV[0];

my $state;

my $dbh = DBI->connect( "DBI:mysql:database=".ZM_DB_NAME.";host=".ZM_DB_HOST, ZM_DB_USER, ZM_DB_PASS );

if ( !$command || $command !~ /^(?:start|stop|restart|status)$/ )
{
	if ( $command )
	{
		# Check to see if it's a valid run state
		my $sql = "select * from States where Name = '$command'";
		my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
		my $res = $sth->execute() or die( "Can't execute: ".$sth->errstr() );
		if ( $state = $sth->fetchrow_hashref() )
		{
			$state->{Name} = $command;
			$state->{Definitions} = [];
			foreach( split( ',', $state->{Definition} ) )
			{
				my ( $id, $function ) = split( ':', $_ );
				push( @{$state->{Definitions}}, { Id=>$id, Function=>$function } );
			}
			$command = 'state';
		}
		else
		{
			$command = undef;
		}
	}
	if ( !$command )
	{
		print( "Usage: zmpkg.pl <start|stop|restart|status|'state'>\n" );
		exit( -1 );
	}
}

# Move to the right place
chdir( ZM_PATH_WEB ) or die( "Can't chdir to '".ZM_PATH_WEB."': $!" );

my $dbg_id = "";

my $log_file = LOG_FILE;
open( LOG, ">>$log_file" ) or die( "Can't open log file: $!" );
open( STDERR, ">&LOG" ) || die( "Can't dup stderr: $!" );
select( STDERR ); $| = 1;
select( LOG ); $| = 1;

Info( "Command: $command\n" );

my $web_uid = (getpwnam( ZM_WEB_USER ))[2];
my $web_gid = (getgrnam( ZM_WEB_GROUP ))[2];
if ( $> != $web_uid )
{
	chown( $web_uid, $web_gid, $log_file ) or die( "Can't change permissions on log file: $!" )
}

my $retval = 0;

# Determine the appropriate syntax for the su command

my $cmd_prefix = getCmdPrefix();

if ( $command eq "state" )
{
	Info( "Updating DB: $state->{Name}\n" );
	my $sql = "select * from Monitors order by Id asc";
	my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
	my $res = $sth->execute() or die( "Can't execute: ".$sth->errstr() );
	while( my $monitor = $sth->fetchrow_hashref() )
	{
		foreach my $definition ( @{$state->{Definitions}} )
		{
			if ( $monitor->{Id} =~ /^$definition->{Id}$/ )
			{
				$monitor->{NewFunction} = $definition->{Function};
			}
		}
		#next if ( !$monitor->{NewFunction} );
		$monitor->{NewFunction} = 'None' if ( !$monitor->{NewFunction} );
		if ( $monitor->{Function} ne $monitor->{NewFunction} )
		{
			my $sql = "update Monitors set Function = ? where Id = ?";
			my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
			my $res = $sth->execute( $monitor->{NewFunction}, $monitor->{Id} ) or die( "Can't execute: ".$sth->errstr() );
		}
	}
	$sth->finish();

	$command = "restart";
}

if ( $command =~ /^(?:stop|restart)$/ )
{
	my $status = runCommand( "zmdc.pl check" );

	if ( $status eq "running" )
	{
		runCommand( "zmdc.pl shutdown" );
		removeShm();
	}
	else
	{
		$retval = 1;
	}
}

if ( $command =~ /^(?:start|restart)$/ )
{
	my $status = runCommand( "zmdc.pl check" );

	if ( $status eq "stopped" )
	{
		removeShm();
		runCommand( "zmfix" );
		runCommand( "zmdc.pl status" );

		my $sql = "select * from Monitors";
		my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
		my $res = $sth->execute() or die( "Can't execute: ".$sth->errstr() );
		while( my $monitor = $sth->fetchrow_hashref() )
		{
			if ( $monitor->{Function} ne 'None' )
			{
				if ( $monitor->{Type} eq 'Local' )
				{
					runCommand( "zmdc.pl start zmc -d $monitor->{Device}" );
				}
				else
				{
					runCommand( "zmdc.pl start zmc -m $monitor->{Id}" );
				}
				if ( $monitor->{Function} ne 'Monitor' )
				{
					if ( ZM_OPT_FRAME_SERVER )
					{
						runCommand( "zmdc.pl start zmf -m $monitor->{Id}" );
					}
					runCommand( "zmdc.pl start zma -m $monitor->{Id}" );
				}
				if ( ZM_OPT_CONTROL )
				{
					if ( $monitor->{Function} eq 'Modect' || $monitor->{Function} eq 'Mocord' )
					{
						if ( $monitor->{Controllable} && $monitor->{TrackMotion} )
						{
							runCommand( "zmdc.pl start zmtrack.pl -m $monitor->{Id}" );
						}
					}
				}
			}
		}
		$sth->finish();

		# This is now started unconditionally
		runCommand( "zmdc.pl start zmfilter.pl" );
		runCommand( "zmdc.pl start zmaudit.pl -d 900 -y" );

		if ( ZM_OPT_TRIGGERS )
		{
			runCommand( "zmdc.pl start zmtrigger.pl" );
		}
		if ( ZM_OPT_X10 )
		{
			runCommand( "zmdc.pl start zmx10.pl -c start" );
		}
		runCommand( "zmdc.pl start zmwatch.pl" );
		if ( ZM_CHECK_FOR_UPDATES )
		{
			runCommand( "zmdc.pl start zmupdate.pl -c" );
		}
	}
	else
	{
		$retval = 1;
	}
}

if ( $command eq "status" )
{
	my $status = runCommand( "zmdc.pl check" );

	print( STDOUT $status."\n" );
}

exit( $retval );

sub getCmdPrefix
{
	Debug( "Testing valid shell syntax\n" );

	my ( $name ) = getpwuid( $> );
	if ( $name eq ZM_WEB_USER )
	{
		Debug( "Running as '$name', su commands not needed\n" );
		return( "" );
	}

	my $null_command = "true";
	my $prefix = "su ".ZM_WEB_USER." -c ";
	my $command = $prefix."'".$null_command."'";
	Debug( "Testing '$command'\n" );
	my $output = qx($command);
	my $status = $? >> 8;
	if ( !$status )
	{
		Debug( "Test ok, using prefix '$prefix'\n" );
		return( $prefix );
	}
	else
	{
		chomp( $output );
		Debug( "Test failed, '$output'\n" );

		$prefix = "su ".ZM_WEB_USER." --shell=/bin/sh --command=";
		$command = $prefix."'true'";
		Debug( "Testing '$command'\n" );
		$output = qx($command);
		$status = $? >> 8;
		if ( !$status )
		{
			Debug( "Test ok, using prefix '$prefix'\n" );
			return( $prefix );
		}
		else
		{
			chomp( $output );
			Debug( "Test failed, '$output'\n" );
		}
	}

	Error( "Unable to find valid 'su' syntax\n" );
	exit( -1 );
}

sub removeShm
{
	Debug( "Removing shared memory\n" );
	# Find ZoneMinder shared memory
	my $command = "ipcs -m | grep '^".substr( sprintf( "0x%x", hex(ZM_SHM_KEY) ), 0, -2 )."'";
	Debug( "Checking for shared memory with '$command'\n" );
	open( CMD, "$command |" ) or die( "Can't execute '$command': $!" );
	while( <CMD> )
	{
		chomp;
		my ( $key, $id ) = split( /\s+/ );
		if ( $id =~ /^(\d+)/ )
		{
			$id = $1;
			$command = "ipcrm shm $id";
			Debug( "Removing shared memory with '$command'\n" );
			qx( $command );
		}
	}
	close( CMD );
}

sub runCommand
{
	my $command = shift;
	$command = $cmd_prefix."'".ZM_PATH_BIN."/".$command."'";
	Debug( "Command: $command\n" );
	my $output = qx($command);
	my $status = $? >> 8;
	chomp( $output );
	if ( $status || DBG_LEVEL > 0 )
	{
		if ( $status )
		{
			Error( "Unable to run '$command', output is '$output'\n" );
			exit( -1 );
		}
		else
		{
			Debug( "Output: $output\n" );
		}
	}
	return( $output );
}
#!/usr/bin/perl

#This script tests the delegation of a list of zones and returns the output in CSV format
#By default is will obtain a list of zones from a DynECT DNS account
#The credentials are read in from a configuration file in the same directory.
#The file is named credentials.cfg in the format:

#user: user_name
#customer: customer_name
#password: password

#Usage: %perl Delegate_check  [-f ListOfZones.txt] [-o OutputFile.txt] [-h]

#Options
#-f --file		Defines a file of line seperated zones to examine
#-o --output	Defines a file for the script to output to
#-h --help 		Prints this help messsage

use warnings;
use strict;
use Config::Simple;
use Getopt::Long;
use LWP::UserAgent;
use JSON;
use Net::DNS;


#Get Options
my $opt_output;
my $opt_file;
my $opt_help;

GetOptions( 
	'output=s' 	=> 	\$opt_output,
	'file=s'	=> 	\$opt_file,
	'help'		=>	\$opt_help,
);


if ( $opt_help ) {
	print "This script tests the delegation of a list of zones and returns the output in CSV format\n";
	print "By default is will obtain a list of zones from you DynECT DNS account as defined in config.cfg\n";
	print "\t-f --file\tDefines a file of line seperated zones to examine\n";
	print "\t-o --output\tDefines a file for the script to output to\n";
	print "\t-h --help\tPrints this help messsage\n";
	exit;
}

#array to store zones for testing
my @zones;

#branch for obtaining zones in account via API (default behavior)
if ( !$opt_file ) {

	#Create config reader
	my $cfg = new Config::Simple();

	# read configuration file (can fail)
	$cfg->read('config.cfg') or die $cfg->error();

	#dump config variables into hash for later use
	my %configopt = $cfg->vars();
	my $apicn = $configopt{'cn'} or do {
		print "Customer Name required in config.cfg for API login\n";
		exit;
	};

	my $apiun = $configopt{'un'} or do {
		print "User Name required in config.cfg for API login\n";
		exit;
	};

	my $apipw = $configopt{'pw'} or do {
		print "User password required in config.cfg for API login\n";
		exit;
	};

	#API login
	my $session_uri = 'https://api2.dynect.net/REST/Session';
	my %api_param = ( 
		'customer_name' => $apicn,
		'user_name' => $apiun,
		'password' => $apipw,
		);

	my $api_request = HTTP::Request->new('POST',$session_uri);
	$api_request->header ( 'Content-Type' => 'application/json' );
	$api_request->content( to_json( \%api_param ) );

	my $api_lwp = LWP::UserAgent->new;
	$api_lwp->timeout(30);
	my $api_result = $api_lwp->request( $api_request );
	my $api_decode;
	my $api_key;
	if ($api_result->is_success) {
		$api_decode = decode_json( $api_result->content);
		$api_key = $api_decode->{'data'}->{'token'};
	}
	else {
		die $api_result->status_line;
	}

	my $zone_uri = "https://api2.dynect.net/REST/Zone/";
	$api_request = HTTP::Request->new('GET',$zone_uri);
	$api_request->header ( 'Content-Type' => 'application/json', 'Auth-Token' => $api_key );
	$api_request->content( '' );
	$api_result = $api_lwp->request($api_request);
	$api_decode = decode_json( $api_result->content);
	$api_decode = &api_fail(\$api_key, $api_decode) unless ($api_decode->{'status'} eq 'success');

	foreach my $zone ( @{$api_decode->{'data'}} ) {
		$zone =~ m/\/REST\/Zone\/(\S+)\/$/;
		push @zones, $1;
	}

	#api logout
	$api_request = HTTP::Request->new('DELETE',$session_uri);
	$api_request->header ( 'Content-Type' => 'application/json', 'Auth-Token' => $api_key );
	$api_result = $api_lwp->request( $api_request );
	$api_decode = decode_json ( $api_result->content);


}

#reading from file
else {
	open my $fh, '<', $opt_file;
	while ( <$fh> ) {
		chomp $_;
		push @zones, $_;
	}
}

my $fh;
if ($opt_output) {
	   open( $fh, '>', $opt_output) 
	   	or die "Unable to open file $opt_output.  Stopped at";
} else {
	   $fh = \*STDOUT or die;
}

my $res = Net::DNS::Resolver->new;
my $junk = $res->tcp_timeout(10);
$junk = $res->udp_timeout(10);

foreach my $zone ( @zones ) {
	my $ans = $res->query($zone, 'NS');
	if ($ans) {
		my $found = 0;
		my @ns;
		foreach my $rr ($ans->answer) {
			next unless $rr->type eq 'NS';
			unshift @ns, $rr->nsdname;
		}
		print $fh $zone;
		foreach (sort @ns) {
			print $fh ",$_";
		}
	print $fh "\n";
	}

	else {
		if ( $res->errorstring ne 'NXDOMAIN' ) {
			print $fh "$zone, Query failed,$res->errorstring\n";
		}	

		else {
			print $fh "$zone,NXDOMAIN\n";
		}
	}	
}


#Expects 2 variable, first a reference to the API key and second a reference to the decoded JSON response
sub api_fail {
	my ($api_keyref, $api_jsonref) = @_;
	#set up variable that can be used in either logic branch
	my $api_request;
	my $api_result;
	my $api_decode;
	my $api_lwp = LWP::UserAgent->new;
	my $count = 0;
	#loop until the job id comes back as success or program dies
	while ( $api_jsonref->{'status'} ne 'success' ) {
		if ($api_jsonref->{'status'} ne 'incomplete') {
			foreach my $msgref ( @{$api_jsonref->{'msgs'}} ) {
				print "API Error:\n";
				print "\tInfo: $msgref->{'INFO'}\n" if $msgref->{'INFO'};
				print "\tLevel: $msgref->{'LVL'}\n" if $msgref->{'LVL'};
				print "\tError Code: $msgref->{'ERR_CD'}\n" if $msgref->{'ERR_CD'};
				print "\tSource: $msgref->{'SOURCE'}\n" if $msgref->{'SOURCE'};
			};
			#api logout or fail
			$api_request = HTTP::Request->new('DELETE','https://api2.dynect.net/REST/Session');
			$api_request->header ( 'Content-Type' => 'application/json', 'Auth-Token' => $$api_keyref );
			$api_result = $api_lwp->request( $api_request );
			$api_decode = decode_json ( $api_result->content);
			exit;
		}
		else {
			print "Loop delay\n";
			sleep(5);
			my $job_uri = "https://api2.dynect.net/REST/Job/$api_jsonref->{'job_id'}/";
			$api_request = HTTP::Request->new('GET',$job_uri);
			$api_request->header ( 'Content-Type' => 'application/json', 'Auth-Token' => $$api_keyref );
			$api_result = $api_lwp->request( $api_request );
			$api_jsonref = decode_json( $api_result->content );
		}
	}
	$api_jsonref;
}

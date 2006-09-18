## OpenXPKI::Server::API.pm 
##
## Written 2005 by Michael Bell and Martin Bartosch for the OpenXPKI project
## Copyright (C) 2005-2006 by The OpenXPKI Project
## $Revision$

package OpenXPKI::Server::API;

use strict;
use warnings;
use utf8;
use English;

use Class::Std;

use Data::Dumper;

use Regexp::Common;
use Params::Validate qw( validate :types );

use OpenXPKI::Debug 'OpenXPKI::Server::API';
use OpenXPKI::Exception;
use OpenXPKI::Server::Context qw( CTX );
use OpenXPKI::DN;
use OpenXPKI::Server::API::Workflow;
use OpenXPKI::Server::API::Object;
use OpenXPKI::Server::API::Visualization;

my %workflow :ATTR;
my %object   :ATTR;
my %visualization :ATTR;

sub BUILD {
    my ($self, $ident, $arg_ref) = @_;
    
    Params::Validate::validation_options(
	# let parameter validation errors throw a proper exception
	on_fail => sub {
	    my $error = shift;
	    
	    OpenXPKI::Exception->throw (
		message => "I18N_OPENXPKI_SERVER_API_INVALID_PARAMETER",
		params => {
		    ERROR => $error,
		});
	},
	);

    $workflow{$ident} = OpenXPKI::Server::API::Workflow->new ($arg_ref);
    $object{$ident}   = OpenXPKI::Server::API::Object->new ($arg_ref);
    $visualization{$ident} = OpenXPKI::Server::API::Visualization->new ($arg_ref);
}

sub get_api
{
    my $self  = shift;
    my $ident = ident $self;
    my $api   = shift;

    return $workflow{$ident} if ($api eq "Workflow");
    return $object{$ident}   if ($api eq "Object");
    return $visualization{$ident}   if ($api eq "Visualization");
    return $self; ## unknown APIs are handled by the core API
}

###########################################################################
# API: simple retrieval functions

# get current pki realm
sub get_pki_realm {
    my $self  = shift;
    my $ident = ident $self;
    my $args  = shift;

    return CTX('session')->get_pki_realm();
}

# get current user
sub get_user {
    my $self  = shift;
    my $ident = ident $self;
    my $args  = shift;

    return CTX('session')->get_user();
}

# get current user
sub get_role {
    my $self  = shift;
    my $ident = ident $self;
    my $args  = shift;

    return CTX('session')->get_role();
}


sub get_chain {
    my $self    = shift;
    my $ident   = ident $self;
    my $arg_ref = shift;
    my $return_ref;
    my @identifiers;
    my @certificates;
    my $finished = 0;
    my $complete = 0;
    my %already_seen; # hash of identifiers that have already been seen

    if (! defined $arg_ref->{START_IDENTIFIER}) {
	OpenXPKI::Exception->throw(
	    message => "I18N_OPENXPKI_SERVER_API_GET_CHAIN_START_IDENTIFIER_MISSING",
        );
    }
    if (defined $arg_ref->{OUTFORMAT}) {
	OpenXPKI::Exception->throw(
	    message => "I18N_OPENXPKI_SERVER_API_GET_CHAIN_OUTFORMAT_NOT_IMPLEMENTED_YET",
        );
    }
    my $start = $arg_ref->{START_IDENTIFIER};
    my $current_identifier = $start;
    my $dbi = CTX('dbi_backend');

    while (! $finished) {
        push @identifiers, $current_identifier;
        my $cert = $dbi->first(
            TABLE   => 'CERTIFICATE',
            DYNAMIC => {
                IDENTIFIER => $current_identifier,
            },
        );
        if (! defined $cert) { #certificate not found
            $finished = 1;
        }
        else {
            if ($cert->{ISSUER_IDENTIFIER} eq $current_identifier) {
                # self-signed, this is the end of the chain
                $finished = 1;
                $complete = 1;
            }
            else { # go to parent
                $current_identifier = $cert->{ISSUER_IDENTIFIER};
                if (defined $already_seen{$current_identifier}) {
                    # we've run into a loop!
                    $finished = 1;
                }
                $already_seen{$current_identifier} = 1;
            }
        }
        # TODO: fill @certificate array
    }
    $return_ref->{IDENTIFIERS} = \@identifiers;
    $return_ref->{COMPLETE}    = $complete;

    return $return_ref;
}

# get one or more CA certificates
# FIXME: this still assumes we have files in the config
sub get_ca_certificate {
    my $self  = shift;
    my $ident = ident $self;
    my $args  = shift;

    my %response;

    ##! 2: "get pki realm configuration"
    my $realms = CTX('pki_realm');
    if (!(defined $realms && (ref $realms eq 'HASH'))) {
	OpenXPKI::Exception->throw (
	    message => "I18N_OPENXPKI_SERVER_API_GET_CA_CERTIFICATES_PKI_REALM_CONFIGURATION_UNAVAILABLE"
        );
    }

    ##! 2: "get session's realm"
    my $thisrealm = CTX('session')->get_pki_realm();
    ##! 2: "$thisrealm"
    if (! defined $thisrealm) {
	OpenXPKI::Exception->throw (
	    message => "I18N_OPENXPKI_SERVER_API_GET_CA_CERTIFICATES_PKI_REALM_NOT_SET"
	);
    }

    if (exists $realms->{$thisrealm}->{ca}) {
	# if no ca certificates could be found this key will not exist
        ##! 4: "ca cert exists"
	foreach my $caid (keys %{$realms->{$thisrealm}->{ca}->{id}}) {
            my $notbefore = $realms->{$thisrealm}->{ca}->{id}->{$caid}->{notbefore};
            my $notafter  = $realms->{$thisrealm}->{ca}->{id}->{$caid}->{notafter};
	    $response{$caid} = 
	    {
		notbefore => OpenXPKI::DateTime::convert_date(
		    {
			DATE => $notbefore,
			OUTFORMAT => 'printable',
		    }),
		notafter => OpenXPKI::DateTime::convert_date(
		    {
			DATE => $notafter,
			OUTFORMAT => 'printable',
		    }),
		cacert => $realms->{$thisrealm}->{ca}->{id}->{$caid}->{crypto}->get_certfile(),

	    };
	}
    }
    ##! 64: "response: " . Dumper(%response)
    return \%response;
}

sub list_ca_ids {
    my $self  = shift;
    my $ident = ident $self;
    my $args  = shift;

    my %response;

    ##! 2: "get pki realm configuration"
    my $realms = CTX('pki_realm');
    if (!(defined $realms && (ref $realms eq 'HASH'))) {
	OpenXPKI::Exception->throw (
	    message => "I18N_OPENXPKI_SERVER_API_LIST_CA_IDS_PKI_REALM_CONFIGURATION_UNAVAILABLE"
        );
    }

    ##! 2: "get session's realm"
    my $thisrealm = CTX('session')->get_pki_realm();
    ##! 2: "$thisrealm"
    if (! defined $thisrealm) {
	OpenXPKI::Exception->throw (
	    message => "I18N_OPENXPKI_SERVER_API_LIST_CA_IDS_PKI_REALM_NOT_SET"
	);
    }
    
    ##! 32: Dumper($realms->{$thisrealm}->{ca})
    if (exists $realms->{$thisrealm}->{ca}) {
        ##! 64: 'if!'
        my @return = sort keys %{$realms->{$thisrealm}->{ca}->{id}};
        ##! 64: Dumper(\@return)
	return @return;
    }
    
    return;
}

sub get_pki_realm_index
{
    my $self = shift;
    my $pki_realm = CTX('session')->get_pki_realm();

    ## scan for correct pki realm
    my $index = CTX('xml_config')->get_xpath_count (XPATH => "pki_realm");
    for (my $i=0; $i < $index; $i++)
    {
        if (CTX('xml_config')->get_xpath (XPATH   => ["pki_realm", "name"],
                                          COUNTER => [$i, 0])
            eq $pki_realm)
        {
            $index = $i;
        } else {
            if ($index == $i+1)
            {
                OpenXPKI::Exception->throw (
                    message => "I18N_OPENXPKI_SERVER_API_GET_PKI_REALM_INDEX_FAILED");
            }
        }
    }

    return $index;
}

sub get_roles
{
    my $self = shift;
    return [ CTX('acl')->get_roles() ];
}

sub get_cert_profiles
{
    my $self = shift;
    my $args = shift;

    my $index = $self->get_pki_realm_index();

    ## get all available profiles
    my %profiles = ();
    my $count = CTX('xml_config')->get_xpath_count (
                    XPATH   => ["pki_realm", "common", "profiles", "endentity", "profile"],
                    COUNTER => [$index, 0, 0, 0]);
    for (my $i=0; $i <$count; $i++)
    {
        my $id = CTX('xml_config')->get_xpath (
                    XPATH   => ["pki_realm", "common", "profiles", "endentity", "profile", "id"],
                    COUNTER => [$index, 0, 0, 0, $i, 0]);
        next if ($id eq "default");
        $profiles{$id} = $i;
    }

    return \%profiles;
}

sub get_cert_subject_profiles
{
    my $self = shift;
    my $args = shift;

    my $index   = $self->get_pki_realm_index();
    my $profile = $args->{PROFILE};

    ## get index of profile
    my $profiles = $self->get_cert_profiles();
       $profile  = $profiles->{$profile};

    ## get all available profiles
    my %profiles = ();
    my $count = CTX('xml_config')->get_xpath_count (
                    XPATH   => ["pki_realm", "common", "profiles", "endentity", "profile", "subject"],
                    COUNTER => [$index, 0, 0, 0, $profile]);
    for (my $i=0; $i <$count; $i++)
    {
        my $id = CTX('xml_config')->get_xpath (
                    XPATH   => ["pki_realm", "common", "profiles", "endentity", "profile", "subject", "id"],
                    COUNTER => [$index, 0, 0, 0, $profile, $i, 0]);
        my $label = CTX('xml_config')->get_xpath (
                    XPATH   => ["pki_realm", "common", "profiles", "endentity", "profile", "subject", "label"],
                    COUNTER => [$index, 0, 0, 0, $profile, $i, 0]);
        my $desc = CTX('xml_config')->get_xpath (
                    XPATH   => ["pki_realm", "common", "profiles", "endentity", "profile", "subject", "description"],
                    COUNTER => [$index, 0, 0, 0, $profile, $i, 0]);
        $profiles{$id}->{LABEL}       = $label;
        $profiles{$id}->{DESCRIPTION} = $desc;
    }

    return \%profiles;
}

1;
__END__

=head1 Name

OpenXPKI::Server::API

=head1 Description

This is the interface which should be used by all user interfaces of OpenXPKI.
A user interface MUST NOT access the server directly. The only allowed
access is via this API. Any function which is not available in this API is
not for public use.
The API gets access to the server via the 'server' context object. This
object must be set before instantiating the API.

=head1 Functions

=head2 new

Default constructor created by Class::Std.

=head2 get_api

return the requested API. Example:

my $api = $api->get_api ("Workflow"); 

=head2 get_user

Get session user.

=head2 get_role

Get session user's role.

=head2 get_pki_realm

Get PKI realm for this session.

=head2 get_ca_ids

Returns a list of all issuing CA IDs that are available.
Return structure:
  CA_ID => array ref of CA IDs

=head2 get_ca_certificate

Returns CA certificate details.
Expects named parameter 'CA_ID' which can be either a scalar or an 
array ref indicating which CA certificates to fetch.
If named paramter 'OUTFORM' is specified, it must be one of 'PEM' or
'DER'. In this case the returned structure will return the CA certificate
in the specified format.

Returns an array ref containing the CA certificate information in the
order that was requested.

Return structure:
  CACERT => [
    {
        CA_ID => CA ID (as requested)
        NOTBEFORE => certifiate notbefore (ISO8601)
        NOTAFTER => certifiate notafter  (ISO8601)
        CERTIFICATE => certificate data (only if OUTFORM was specified)
    }

  ]

=head2 get_chain

Returns the certificate chain starting at a specified certificate.
Expects a hash ref with the named parameter START_IDENTIFIER (the
identifier from which to compute the chain) and optionally a parameter
OUTFORMAT, which can be either 'PEM' or 'DER'.
Returns a hash ref with the following entries:

    IDENTIFIERS   the chain of certificate identifiers as an array
    CERTIFICATES  the certificates as an array of data in outformat
                  (if requested)
    COMPLETE      1 if the complete chain was found in the database
                  0 otherwise

=head2 get_api

expects the name of the requested API and returns an instance of this API.
Example:

my $workflow_api = $api->get_api('Workflow');
my $object_api   = $api->get_api('Object');
my $visual_api   = $api->get_api('Visualization');
my $api          = $api->get_api('Unknown API');


# OpenXPKI::Server::Workflow::Activity::Tools::PublishCertificate
# Copyright (c) 2009 by The OpenXPKI Project

package OpenXPKI::Server::Workflow::Activity::Tools::PublishCertificate;

use strict;
use English;
use base qw( OpenXPKI::Server::Workflow::Activity );

use OpenXPKI::DN;
use OpenXPKI::Server::Context qw( CTX );
use OpenXPKI::Exception;
use OpenXPKI::Debug;

use Data::Dumper;


sub execute {
    ##! 1: 'start'
    my $self     = shift;
    my $workflow = shift;

    my $default_token = CTX('api')->get_default_token();
    my $config        = CTX('config');

    my $cert_identifier = $self->param('cert_identifier');

    if (!$cert_identifier) {
        $cert_identifier = $workflow->context()->param('cert_identifier');
    }

    if (!$cert_identifier) {
        OpenXPKI::Exception->throw(
            message => 'I18N_OPENXPI_WORKFLOW_ACTIVITY_TOOLS_PUBLISH_CERTIFICATE_USING_PROFILE_NO_CERT_IDENTIFIER'
        );
    }

    my @targets;
    my @path;
    # Detect if we are in profile or prefix mode
    my $prefix = $self->param('prefix');
    if (defined $prefix) {
        if (!$prefix || !$config->exists( $prefix )) {
            CTX('log')->log(
                MESSAGE => 'Publication in prefix mode but prefix not set or empty',
                PRIORITY => 'debug',
                FACILITY => [ 'application' ],
            );
            return 1;
        }

        @path = split /\./, $prefix;
        # Get the list of targets from prefix
        @targets = $config->get_keys( $prefix );

    } else {

        # Profile mode

        ##! 16: 'Lookup profile for identifier ' . $cert_identifier
        my $profile = CTX('api')->get_profile_for_cert({ IDENTIFIER => $cert_identifier });

        if (!$profile) {
            OpenXPKI::Exception->throw(
                message => 'I18N_OPENXPI_WORKFLOW_ACTIVITY_TOOLS_PUBLISH_CERTIFICATE_NO_PROFILE_FOR_CERTIFICATE',
                params => { 'CERT_IDENTIFIER' => $cert_identifier },
            );
        }

        # Check if the node exists inside the profile

        if ($config->exists([ 'profile', $profile, 'publish'])) {
            @targets = $config->get_scalar_as_list( [ 'profile', $profile, 'publish'] );
        } else {
            @targets = $config->get_scalar_as_list( [ 'profile', 'default', 'publish'] );
        }

        # Reuse the prefix value to build the full path
        @path = ( 'publishing','entity' );

    }

    # If the data point does not exist, we get a one item undef array
    return unless (defined @targets && $targets[0]);


    ##! 16: 'Start publishing - load certificate for identifier ' . $cert_identifier

    # Load and convert the certificate
    CTX('dbi_backend')->commit();
    my $hash = CTX('dbi_backend')->first (
        TABLE => 'CERTIFICATE',
        DYNAMIC => {
           IDENTIFIER => { VALUE => $cert_identifier },
        },
    );

    if (!$hash || !$hash->{DATA}) {
        OpenXPKI::Exception->throw(
            message => 'I18N_OPENXPKI_SERVER_WORKFLOW_ACTIVITY_TOOLS_PUBLISH_CERTIFICATE_UNABLE_TO_LOAD_CERTIFICATE',
            params => { 'CERT_IDENTIFIER' => $cert_identifier },
            log => {
                logger => CTX('log'),
                priority => 'error',
                facility => 'system',
            },
        );
    }

    CTX('log')->log(
        MESSAGE => 'Publication for ' . $hash->{SUBJECT} . ', targets ' . join(",", @targets),
        PRIORITY => 'debug',
        FACILITY => [ 'application' ],
    );

    # Prepare the data
    my $data = {};
    $data->{pem} = $hash->{DATA};
    $data->{subject} = $hash->{SUBJECT};

    # Convert to DER
    $data->{der} = $default_token->command({
        COMMAND => 'convert_cert',
        DATA    => $data->{pem},
        OUT     => 'DER',
    });

    if (!defined $data->{der} || $data->{der} eq '') {
        OpenXPKI::Exception->throw(
            message => 'I18N_OPENXPKI_SERVER_WORKFLOW_ACTIVITY_TOOLS_PUBLISH_CERTIFICATES_COULD_NOT_CONVERT_CERT_TO_DER',
            log => {
            logger => CTX('log'),
                priority => 'error',
                facility => 'system',
            },
        );
    }

    ##! 32: 'Data for publication '. Dumper ( $data )

    CTX('log')->log(
        MESSAGE => 'Start publication for ' .$data->{subject},
        PRIORITY => 'info',
        FACILITY => [ 'application' ],
    );

    # Strip the common name to be used as publishing key
    my $dn_parser = OpenXPKI::DN->new( $data->{subject} );

    my %rdn_hash = $dn_parser->get_hashed_content();

    my $param;
    if ($self->param('export_context')) {
       $param->{context} = $workflow->context()->param();
    }

    foreach my $target (@targets) {
        ##! 32: " $target . $rdn_hash{CN}[0] "
        my $res = $config->set( [  @path, $target, $rdn_hash{CN}[0] ], $data, $param );
        ##! 16 : 'Publish at target ' . $target . ' - Result: ' . $res
    }

    ##! 4: 'end'
    return 1;
}

1;
__END__

=head1 Name

OpenXPKI::Server::Workflow::Activity::Tools::PublishCertificate

=head1 Description

This class publishes a single certificate based on the publishing information
associated with the certificate profile or a given prefix. The certificate is
identified by the parameter cert_identifier which can be set in the action
definition. If unset, the class falls back to the context value of cert_identifier.

The publishing information is read from the connector at profile.<profile name>.publish
which must be a list of names (scalar is also ok). If the node does not exists,
profile.default.publish is used. Each name is expanded to the path
publishing.entity.<name> which must be a connector reference. Each connector is
called with the value of the certificates common name as location. The data portion
contains a hash ref with the keys I<pem>, I<der> and I<subject> (full dn of the cert).

To use profile independant publication, specify the parameter I<prefix> which must
point to a scalar/list of connector references.

=head1 Configuration

Set the wanted connector names in the certificates profile:

  publish:
    - extldap
    - exthttp

Define the connector references and implementations in publishing.yaml

  entity:
      extldap@: connector: publishing.connectors.ext-ldap
      exthttp@: connector: publishing.connectors.ext-http

  connectors:
    ext-ldap:
      class: Connector::Proxy::Net::LDAP::Single
      LOCATION: ldap://localhost:389
      ....

=head2 Activity parameters

=over

=item prefix

Enables publishing to a fixed set of connectors, disables per profile settings.

=item cert_identifier

Set the identifier of the cert to publish, optional, default is the value
of the context key cert_identifier.

=item export_context

Boolean, if set the full context is passed to the connector in the third argument.

=back

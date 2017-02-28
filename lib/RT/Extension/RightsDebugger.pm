package RT::Extension::RightsDebugger;
use strict;
use warnings;

our $VERSION = '0.01';

RT->AddStyleSheets("rights-debugger.css");
RT->AddJavaScript("rights-debugger.js");
RT->AddJavaScript("handlebars-4.0.6.min.js");

sub SerializeACE {
    my $self = shift;
    my $ACE = shift;

    return {
        principal => $self->SerializeRecord($ACE->PrincipalObj),
        object    => $self->SerializeRecord($ACE->Object),
        right     => $ACE->RightName,
    };
}

sub SerializeRecord {
    my $self = shift;
    my $record = shift;

    if ($record->isa('RT::Principal')) {
        $record = $record->Object;
    }

    if ($record->isa('RT::Group')) {
        if ($record->Domain eq 'ACLEquivalence') {
            my $principal = RT::Principal->new($record->CurrentUser);
            $principal->Load($record->Instance);
            $record = $principal->Object;
        }
        elsif ($record->Domain =~ /-Role$/) {
            my ($id) = $record->Name =~ /^RT::CustomRole-(\d+)$/;
            if ($id) {
                my $role = RT::CustomRole->new($record->CurrentUser);
                $role->Load($id);
                $record = $role;
            }
        }
    }

    my $type = ref($record);
    $type =~ s/^RT:://;

    my $show_detail = 1;
    $show_detail = 0 if $record->isa('RT::System');

    my $show_id = 1;
    $show_id = 0 if $record->isa('RT::Group') && $record->Domain eq 'SystemInternal';

    return {
        class       => ref($record),
        id          => $record->id,
        label       => $self->LabelForRecord($record),
        url         => $self->URLForRecord($record),
        type        => $type,
        show_detail => $show_detail,
        show_id     => $show_id,
    };
}

sub LabelForRecord {
    my $self = shift;
    my $object = shift;

    return $object->Name;
}

sub URLForRecord {
    my $self = shift;
    my $object = shift;
    my $id = $object->id;

    if ($object->isa('RT::Queue')) {
        return RT->Config->Get('WebURL') . 'Admin/Queues/Modify.html?id=' . $id;
    }
    elsif ($object->isa('RT::User')) {
        return undef if $id == RT->SystemUser->id
                     || $id == RT->Nobody->id;

        return RT->Config->Get('WebURL') . 'Admin/Users/Modify.html?id=' . $id;
    }
    elsif ($object->isa('RT::Group')) {
        return undef unless $object->Domain eq 'UserDefined';
        return RT->Config->Get('WebURL') . 'Admin/Groups/Modify.html?id=' . $id;
    }
    elsif ($object->isa('RT::CustomField')) {
        return RT->Config->Get('WebURL') . 'Admin/CustomFields/Modify.html?id=' . $id;
    }
    elsif ($object->isa('RT::Class')) {
        return RT->Config->Get('WebURL') . 'Admin/Articles/Classes/Modify.html?id=' . $id;
    }
    elsif ($object->isa('RT::Catalog')) {
        return RT->Config->Get('WebURL') . 'Admin/Assets/Catalogs/Modify.html?id=' . $id;
    }
    elsif ($object->isa('RT::CustomRole')) {
        return RT->Config->Get('WebURL') . 'Admin/CustomRoles/Modify.html?id=' . $id;
    }

    return undef;
}

=head1 NAME

RT-Extension-RightsDebugger - 

=head1 INSTALLATION

=over

=item perl Makefile.PL

=item make

=item make install

This step may require root permissions.

=item Edit your /opt/rt4/etc/RT_SiteConfig.pm

Add this line:

    Plugin( "RT::Extension::RightsDebugger" );

=item Clear your mason cache

    rm -rf /opt/rt4/var/mason_data/obj

=item Restart your webserver

=back

=head1 AUTHOR

Best Practical Solutions, LLC E<lt>modules@bestpractical.comE<gt>

=head1 BUGS

All bugs should be reported via email to

    L<bug-RT-Extension-RightsDebugger@rt.cpan.org|mailto:bug-RT-Extension-RightsDebugger@rt.cpan.org>

or via the web at

    L<rt.cpan.org|http://rt.cpan.org/Public/Dist/Display.html?Name=RT-Extension-RightsDebugger>.

=head1 COPYRIGHT

This extension is Copyright (C) 2017 Best Practical Solutions, LLC.

This is free software, licensed under:

  The GNU General Public License, Version 2, June 1991

=cut

1;

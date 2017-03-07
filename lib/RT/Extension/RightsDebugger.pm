package RT::Extension::RightsDebugger;
use strict;
use warnings;

our $VERSION = '0.01';

RT->AddStyleSheets("rights-debugger.css");
RT->AddJavaScript("rights-debugger.js");
RT->AddJavaScript("handlebars-4.0.6.min.js");


$RT::Interface::Web::WHITELISTED_COMPONENT_ARGS{'/Admin/RightsDebugger/index.html'} = ['Principal', 'Object', 'Right'];

sub CurrentUser {
    return $HTML::Mason::Commands::session{CurrentUser};
}

sub _EscapeHTML {
    my $s = shift;
    RT::Interface::Web::EscapeHTML(\$s);
    return $s;
}

sub _HighlightTerm {
    my ($text, $re) = @_;

    $text =~ s{
        \G         # where we left off the previous iteration thanks to /g
        (.*?)      # non-matching text before the match
        ($re|$)    # matching text, or the end of the line (to escape any
                   # text after the last match)
    }{
      _EscapeHTML($1) .
      (length $2 ? '<span class="match">' . _EscapeHTML($2) . '</span>' : '')
    }xeg;

    return $text; # now escaped as html
}

sub _HighlightSerializedForSearch {
    my $serialized = shift;
    my $search     = shift;

    # highlight matching words
    $serialized->{right_highlighted} = _HighlightTerm($serialized->{right}, join '|', @{ $search->{right} || [] });

    for my $key (qw/principal object/) {
        my $record = $serialized->{$key};

        if (my $matchers = $search->{$key}) {
            my $re = join '|', @$matchers;
            for my $column (qw/label detail/) {
                $record->{$column . '_highlighted'} = _HighlightTerm($record->{$column}, $re);
            }
        }

        for my $column (qw/label detail/) {
            # make sure we escape html if there was no search
            $record->{$column . '_highlighted'} //= _EscapeHTML($record->{$column});
        }
    }

    return;
}

sub _PrincipalForSpec {
    my $self       = shift;
    my $type       = shift;
    my $identifier = shift;

    if ($type =~ /^g/i) {
        my $group = RT::Group->new($self->CurrentUser);
        if ( $identifier =~ /^\d+$/ ) {
            $group->LoadByCols(
                id => $identifier,
            );
        } else {
            $group->LoadByCols(
                Domain => 'UserDefined',
                Name   => $identifier,
            );
        }

        return $group->PrincipalObj if $group->Id;
    }
    else {
        my $user = RT::User->new($self->CurrentUser);
        $user->Load($identifier);
        return $user->PrincipalObj if $user->Id;
    }

    return undef;
}

sub Search {
    my $self = shift;
    my %args = (
        principal => '',
        object    => '',
        right     => '',
        @_,
    );

    my @results;
    my %search;

    my $ACL = RT::ACL->new($self->CurrentUser);

    my $has_search = 0;
    my %use_regex_search_for = (
        principal => 1,
        object    => 1,
    );
    my %primary_records = (
        principal => undef,
        object    => undef,
    );

    if ($args{principal}) {
        if (my ($type, $identifier) = $args{principal} =~ m{
            ^
                \s*
                (u|user|g|group)
                \s*
                [:#]
                \s*
                (.+?)
                \s*
            $
        }xi) {
            my $principal = $self->_PrincipalForSpec($type, $identifier);
            if (!$principal) {
                return { error => 'Unable to find row' };
            }

            $has_search = 1;
            $use_regex_search_for{principal} = 0;

            $primary_records{principal} = $principal;

            my $principal_alias = $ACL->Join(
                ALIAS1 => 'main',
                FIELD1 => 'PrincipalId',
                TABLE2 => 'Principals',
                FIELD2 => 'id',
            );

            my $cgm_alias = $ACL->Join(
                ALIAS1 => 'main',
                FIELD1 => 'PrincipalId',
                TABLE2 => 'CachedGroupMembers',
                FIELD2 => 'GroupId',
            );
            $ACL->Limit(
                ALIAS => $cgm_alias,
                FIELD => 'Disabled',
                VALUE => 0,
            );
            $ACL->Limit(
                ALIAS => $cgm_alias,
                FIELD => 'MemberId',
                VALUE => $principal->Id,
            );
        }
    }

    if ($args{right}) {
        $has_search = 1;
        for my $word (split ' ', $args{right}) {
            $ACL->Limit(
                FIELD           => 'RightName',
                OPERATOR        => 'LIKE',
                VALUE           => $word,
                CASESENSITIVE   => 0,
                ENTRYAGGREGATOR => 'OR',
            );
        }
    }

    if ($args{continueAfter}) {
        $has_search = 1;
        $ACL->Limit(
            FIELD    => 'id',
            OPERATOR => '>',
            VALUE    => $args{continueAfter},
        );
    }

    $ACL->OrderBy(
        ALIAS => 'main',
        FIELD => 'id',
        ORDER => 'ASC',
    );

    $ACL->UnLimit unless $has_search;

    $ACL->RowsPerPage(100);

    for my $key (qw/principal object right/) {
        if (my $search = $args{$key}) {
            my @matchers;
            for my $word ($key eq 'right' ? (split ' ', $search) : $search) {
                push @matchers, qr/\Q$word\E/i;
            }
            $search{$key} = \@matchers;
        }
    }

    my $continueAfter;

    ACE: while (my $ACE = $ACL->Next) {
        $continueAfter = $ACE->Id;
        my $serialized = $self->SerializeACE($ACE, \%primary_records);

        KEY: for my $key (qw/principal object/) {
	    # filtering on the serialized record is hacky, but doing the
	    # searching in SQL is absolutely a nonstarter
            next KEY unless $use_regex_search_for{$key};

            if (my $matchers = $search{$key}) {
                my $record = $serialized->{$key};
                for my $re (@$matchers) {
                    next KEY if $record->{class}  =~ $re
                             || $record->{id}     =~ $re
                             || $record->{label}  =~ $re
                             || $record->{detail} =~ $re;
                }

                # no matches
                next ACE;
            }
        }

        _HighlightSerializedForSearch($serialized, \%search);

        push @results, $serialized;
    }

    # if we didn't fill the whole page, then we know there are
    # no more rows to consider
    undef $continueAfter if $ACL->Count < $ACL->RowsPerPage;

    return {
        results => \@results,
        continueAfter => $continueAfter,
    };
}

sub SerializeACE {
    my $self = shift;
    my $ACE = shift;
    my $primary_records = shift;

    return {
        principal      => $self->SerializeRecord($ACE->PrincipalObj, $primary_records->{principal}),
        object         => $self->SerializeRecord($ACE->Object, $primary_records->{object}),
        right          => $ACE->RightName,
        ace            => { id => $ACE->Id },
        disable_revoke => $self->DisableRevoke($ACE),
    };
}

sub DisableRevoke {
    my $self = shift;
    my $ACE = shift;
    my $Principal = $ACE->PrincipalObj;
    my $Object    = $ACE->Object;
    my $Right     = $ACE->RightName;

    if ($Principal->Object->Domain eq 'ACLEquivalence') {
        my $User = $Principal->Object->InstanceObj;
        if ($User->Id == RT->SystemUser->Id && $Object->isa('RT::System') && $Right eq 'SuperUser') {
            return 1;
        }
        if ($User->Id == RT->Nobody->Id && $Object->isa('RT::System') && $Right eq 'OwnTicket') {
            return 1;
        }
    }

    return 0;
}

sub SerializeRecord {
    my $self = shift;
    my $record = shift;
    my $primary_record = shift;

    return undef unless $record;

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

    my $serialized = {
        class           => ref($record),
        id              => $record->id,
        label           => $self->LabelForRecord($record),
        detail          => $self->DetailForRecord($record),
        url             => $self->URLForRecord($record),
        disabled        => $self->DisabledForRecord($record) ? JSON::true : JSON::false,
        primary_record  => $self->SerializeRecord($primary_record),
    };

    return $serialized;
}

sub LabelForRecord {
    my $self = shift;
    my $record = shift;

    if ($record->isa('RT::Ticket')) {
        return $record->Subject;
    }

    return $record->Name;
}

sub DisabledForRecord {
    my $self = shift;
    my $record = shift;

    if ($record->can('Disabled')) {
        return $record->Disabled;
    }

    return 0;
}

sub DetailForRecord {
    my $self = shift;
    my $record = shift;

    my $id = $record->Id;

    return 'Global System' if $record->isa('RT::System');

    return 'System User' if $record->isa('RT::User')
                         && ($id == RT->SystemUser->Id || $id == RT->Nobody->Id);

    # like RT::Group->SelfDescription but without the redundant labels
    if ($record->isa('RT::Group')) {
        if ($record->RoleClass) {
            my $class = $record->RoleClass;
            $class =~ s/^RT:://i;
            return "$class Role";
        }
        elsif ($record->Domain eq 'SystemInternal') {
            return "System Group";
        }
    }

    my $type = ref($record);
    $type =~ s/^RT:://;

    return $type . ' #' . $id;
}

sub URLForRecord {
    my $self = shift;
    my $record = shift;
    my $id = $record->id;

    if ($record->isa('RT::Queue')) {
        return RT->Config->Get('WebURL') . 'Admin/Queues/Modify.html?id=' . $id;
    }
    elsif ($record->isa('RT::User')) {
        return undef if $id == RT->SystemUser->id
                     || $id == RT->Nobody->id;

        return RT->Config->Get('WebURL') . 'Admin/Users/Modify.html?id=' . $id;
    }
    elsif ($record->isa('RT::Group')) {
        return undef unless $record->Domain eq 'UserDefined';
        return RT->Config->Get('WebURL') . 'Admin/Groups/Modify.html?id=' . $id;
    }
    elsif ($record->isa('RT::CustomField')) {
        return RT->Config->Get('WebURL') . 'Admin/CustomFields/Modify.html?id=' . $id;
    }
    elsif ($record->isa('RT::Class')) {
        return RT->Config->Get('WebURL') . 'Admin/Articles/Classes/Modify.html?id=' . $id;
    }
    elsif ($record->isa('RT::Catalog')) {
        return RT->Config->Get('WebURL') . 'Admin/Assets/Catalogs/Modify.html?id=' . $id;
    }
    elsif ($record->isa('RT::CustomRole')) {
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

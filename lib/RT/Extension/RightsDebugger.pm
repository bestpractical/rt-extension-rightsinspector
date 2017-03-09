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

# used to convert a search term (e.g. "root") into a regex for highlighting
# in the UI. potentially useful hook point for implementing say, "ro*t"
sub RegexifyTermForHighlight {
    my $self = shift;
    my $term = shift || '';
    return qr/\Q$term\E/i;
}

# takes a text label and returns escaped html, highlighted using the search
# term(s)
sub HighlightTextForSearch {
    my $self = shift;
    my $text = shift;
    my $term = shift;

    my $re = ref($term) eq 'ARRAY'
           ? join '|', map { $self->RegexifyTermForHighlight($_) } @$term
           : $self->RegexifyTermForHighlight($term);

    # if $term is an arrayref, make sure we qr-ify it
    # without this, then if $term has no elements, we interpolate $re
    # as an empty string which causes the regex engine to fall into
    # an infinite loop
    $re = qr/$re/ unless ref($re);

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

# takes a serialized result and highlights its labels according to the search
# terms
sub HighlightSerializedForSearch {
    my $self         = shift;
    my $serialized   = shift;
    my $args         = shift;
    my $regex_search = shift;

    # highlight matching terms
    $serialized->{right_highlighted} = $self->HighlightTextForSearch($serialized->{right}, [split ' ', $args->{right} || '']);

    for my $key (qw/principal object/) {
        for my $record ($serialized->{$key}, $serialized->{$key}->{primary_record}) {
            next if !$record;

            # if we used a regex search for this record, then highlight the
            # text that the regex matched
            if ($regex_search->{$key}) {
                for my $column (qw/label detail/) {
                    $record->{$column . '_highlighted'} = $self->HighlightTextForSearch($record->{$column}, $args->{$key});
                }
            }
            # otherwise we used a search like user:root and so we should
            # highlight just that user completely (but not its parent group)
            else {
                $record->{'highlight'} = $record->{primary_record} ? 0 : 1;
                for my $column (qw/label detail/) {
                    $record->{$column . '_highlighted'} = _EscapeHTML($record->{$column});
                }
            }
        }
    }

    return;
}

# takes "u:root" "group:37" style specs and returns the RT::Principal
sub PrincipalForSpec {
    my $self       = shift;
    my $type       = shift;
    my $identifier = shift;

    if ($type =~ /^(g|group)$/i) {
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
    elsif ($type =~ /^(u|user)$/i) {
        my $user = RT::User->new($self->CurrentUser);
        $user->Load($identifier);
        return $user->PrincipalObj if $user->Id;
    }
    else {
        RT->Logger->debug("Unexpected type '$type'");
    }

    return undef;
}

# takes "t#1" "queue:General", "asset:37" style specs and returns that object
# limited to thinks you can grant rights on
sub ObjectForSpec {
    my $self       = shift;
    my $type       = shift;
    my $identifier = shift;

    my $record;

    if ($type =~ /^(t|ticket)$/i) {
        $record = RT::Ticket->new($self->CurrentUser);
    }
    elsif ($type =~ /^(q|queue)$/i) {
        $record = RT::Queue->new($self->CurrentUser);
    }
    elsif ($type =~ /^asset$/i) {
        $record = RT::Asset->new($self->CurrentUser);
    }
    elsif ($type =~ /^catalog$/i) {
        $record = RT::Catalog->new($self->CurrentUser);
    }
    elsif ($type =~ /^(a|article)$/i) {
        $record = RT::Article->new($self->CurrentUser);
    }
    elsif ($type =~ /^class$/i) {
        $record = RT::Class->new($self->CurrentUser);
    }
    elsif ($type =~ /^(g|group)$/i) {
        return $self->PrincipalForSpec($type, $identifier);
    }
    else {
        RT->Logger->debug("Unexpected type '$type'");
        return undef;
    }

    $record->Load($identifier);
    return $record if $record->Id;

    return undef;
}

# key entry point into this extension; takes a query (principal, object, right)
# and produces a list of highlighted results
sub Search {
    my $self = shift;
    my %args = (
        principal => '',
        object    => '',
        right     => '',
        @_,
    );

    my @results;

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

    if ($args{object}) {
        if (my ($type, $identifier) = $args{object} =~ m{
            ^
                \s*
                (t|ticket|q|queue|asset|catalog|a|article|class|g|group)
                \s*
                [:#]
                \s*
                (.+?)
                \s*
            $
        }xi) {
            my $record = $self->ObjectForSpec($type, $identifier);
            if (!$record) {
                return { error => 'Unable to find row' };
            }

            $has_search = 1;
            $use_regex_search_for{object} = 0;

            $primary_records{object} = $record;

            for my $obj ($record, $record->ACLEquivalenceObjects, RT->System) {
                $ACL->LimitToObject($obj);
            }
        }
    }

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
            my $principal = $self->PrincipalForSpec($type, $identifier);
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
        for my $term (split ' ', $args{right}) {
            $ACL->Limit(
                FIELD           => 'RightName',
                OPERATOR        => 'LIKE',
                VALUE           => $term,
                CASESENSITIVE   => 0,
                ENTRYAGGREGATOR => 'OR',
            );
        }
        $ACL->Limit(
            FIELD           => 'RightName',
            OPERATOR        => '=',
            VALUE           => 'SuperUser',
            ENTRYAGGREGATOR => 'OR',
        );
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

    my $continueAfter;

    ACE: while (my $ACE = $ACL->Next) {
        $continueAfter = $ACE->Id;
        my $serialized = $self->SerializeACE($ACE, \%primary_records);

        KEY: for my $key (qw/principal object/) {
	    # filtering on the serialized record is hacky, but doing the
	    # searching in SQL is absolutely a nonstarter
            next KEY unless $use_regex_search_for{$key};

            if (my $term = $args{$key}) {
                my $record = $serialized->{$key};
                my $re = qr/\Q$term\E/i;
                next KEY if $record->{class}  =~ $re
                         || $record->{id}     =~ $re
                         || $record->{label}  =~ $re
                         || $record->{detail} =~ $re;

                # no matches
                next ACE;
            }
        }

        $self->HighlightSerializedForSearch($serialized, \%args, \%use_regex_search_for);

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

# takes an ACE (singular version of ACL) and produces a JSON-serializable
# dictionary for transmitting over the wire
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

# should the "Revoke" button be disabled? by default it is for the two required
# system privileges; if such privileges needed to be revoked they can be done
# through the ordinary ACL management UI
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

# convert principal to its user/group, custom role group to its custom role, etc
sub CanonicalizeRecord {
    my $self = shift;
    my $record = shift;

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

    return $record;
}

# takes a user, group, ticket, queue, etc and produces a JSON-serializable
# dictionary
sub SerializeRecord {
    my $self = shift;
    my $record = shift;
    my $primary_record = shift;

    return undef unless $record;

    $record = $self->CanonicalizeRecord($record);
    $primary_record = $self->CanonicalizeRecord($primary_record);

    undef $primary_record if $primary_record
                          && ref($record) eq ref($primary_record)
                          && $record->Id == $primary_record->Id;

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

# primary display label for a record (e.g. user name, ticket subject)
sub LabelForRecord {
    my $self = shift;
    my $record = shift;

    if ($record->isa('RT::Ticket')) {
        return $record->Subject;
    }

    return $record->Name;
}

# boolean indicating whether the record should be labeled as disabled in the UI
sub DisabledForRecord {
    my $self = shift;
    my $record = shift;

    if ($record->can('Disabled')) {
        return $record->Disabled;
    }

    return 0;
}

# secondary detail information for a record (e.g. ticket #)
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

# most appropriate URL for a record. admin UI preferred, but for objects without
# admin UI (such as ticket) then user UI is fine
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
    elsif ($record->isa('RT::Ticket')) {
        return RT->Config->Get('WebURL') . 'Ticket/Display.html?id=' . $id;
    }
    elsif ($record->isa('RT::Asset')) {
        return RT->Config->Get('WebURL') . 'Asset/Display.html?id=' . $id;
    }
    elsif ($record->isa('RT::Article')) {
        return RT->Config->Get('WebURL') . 'Articles/Article/Display.html?id=' . $id;
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

use MooseX::Declare;
role SQL::Translator::Parser::DDL::XML {
    use MooseX::MultiMethods;
    use MooseX::Types::Moose qw(Any);
    use XML::LibXML;
    use XML::LibXML::XPathContext;
    use aliased 'SQL::Translator::Object::Column';
    use aliased 'SQL::Translator::Object::Constraint';
    use aliased 'SQL::Translator::Object::Index';
    use aliased 'SQL::Translator::Object::Procedure';
    use aliased 'SQL::Translator::Object::Table';
    use aliased 'SQL::Translator::Object::Trigger';
    use aliased 'SQL::Translator::Object::View';
    use SQL::Translator::Types qw(Schema);

multi method parse(Schema $data) { $data }
multi method parse(Any $data) {
    my $translator = $self->translator;
    my $schema                = $translator->schema;
#    local $DEBUG              = $translator->debug;
    my $doc                   = XML::LibXML->new->parse_string($data);
    my $xp                    = XML::LibXML::XPathContext->new($doc);

    $xp->registerNs("sqlf", "http://sqlfairy.sourceforge.net/sqlfairy.xml");

    #
    # Work our way through the tables
    #
    my @nodes = $xp->findnodes(
        '/sqlf:schema/sqlf:table|/sqlf:schema/sqlf:tables/sqlf:table'
    );
    for my $tblnode (
        sort {
            ("".$xp->findvalue('sqlf:order|@order',$a) || 0)
            <=>
            ("".$xp->findvalue('sqlf:order|@order',$b) || 0)
        } @nodes
    ) {
#        debug "Adding table:".$xp->findvalue('sqlf:name',$tblnode);

        my $table = Table->new({
            get_tagfields($xp, $tblnode, "sqlf:" => qw/name order extra/), schema => $schema
        });
        $schema->add_table($table);

        #
        # Fields
        #
        my @nodes = $xp->findnodes('sqlf:fields/sqlf:field',$tblnode);
        foreach (
            sort {
                ("".$xp->findvalue('sqlf:order',$a) || 0)
                <=>
                ("".$xp->findvalue('sqlf:order',$b) || 0)
            } @nodes
        ) {
            my %fdata = get_tagfields($xp, $_, "sqlf:",
                qw/name data_type size default_value is_nullable extra
                is_auto_increment is_primary_key is_foreign_key comments/
            );

            if (
                exists $fdata{'default_value'} and
                defined $fdata{'default_value'}
            ) {
                if ( $fdata{'default_value'} =~ /^\s*NULL\s*$/ ) {
                    $fdata{'default_value'}= undef;
                }
                elsif ( $fdata{'default_value'} =~ /^\s*EMPTY_STRING\s*$/ ) {
                    $fdata{'default_value'} = "";
                }
            }

            $fdata{table} = $table;
            $fdata{sql_data_type} = $self->data_type_mapping->{$fdata{data_type}} || -99999;
            my $field = Column->new(%fdata);
            $table->add_column($field);

            $field->is_primary_key(1) if $fdata{is_primary_key};

            #
            # TODO:
            # - We should be able to make the table obj spot this when
            #   we use add_field.
            #
        }

        #
        # Constraints
        #
        @nodes = $xp->findnodes('sqlf:constraints/sqlf:constraint',$tblnode);
        foreach (@nodes) {
            my %data = get_tagfields($xp, $_, "sqlf:",
                qw/name type table fields reference_fields reference_table
                match_type on_delete on_update extra/
            );

            $data{table} = $table;
            my $constraint = Constraint->new(%data);
            $table->add_constraint($constraint);
        }

        #
        # Indexes
        #
        @nodes = $xp->findnodes('sqlf:indices/sqlf:index',$tblnode);
        foreach (@nodes) {
            my %data = get_tagfields($xp, $_, "sqlf:",
                qw/name type fields options extra/);

            $data{table} = $table;
            my $index = Index->new(%data);
            $table->add_index($index);
        }

        
        #
        # Comments
        #
        @nodes = $xp->findnodes('sqlf:comments/sqlf:comment',$tblnode);
        foreach (@nodes) {
            my $data = $_->string_value;
            $table->comments( $data );
        }

    } # tables loop

    #
    # Views
    #
    @nodes = $xp->findnodes(
        '/sqlf:schema/sqlf:view|/sqlf:schema/sqlf:views/sqlf:view'
    );
    foreach (@nodes) {
        my %data = get_tagfields($xp, $_, "sqlf:",
            qw/name sql fields extra/
        );
        my $view = View->new(%data);
        $schema->add_view($view);
    }

    #
    # Triggers
    #
    @nodes = $xp->findnodes(
        '/sqlf:schema/sqlf:trigger|/sqlf:schema/sqlf:triggers/sqlf:trigger'
    );
    foreach (@nodes) {
        my %data = get_tagfields($xp, $_, "sqlf:", qw/
            name perform_action_when database_event database_events fields
            on_table action extra
        /);

        # back compat
        if (my $evt = $data{database_event} and $translator->{show_warnings}) {
#          carp 'The database_event tag is deprecated - please use ' .
#            'database_events (which can take one or more comma separated ' .
#            'event names)';
          $data{database_events} = join (', ',
            $data{database_events} || (),
            $evt,
          );
        }

        # split into arrayref
        if (my $evts = $data{database_events}) {
          $data{database_events} = [split (/\s*,\s*/, $evts) ];
        }
        my $trigger = Trigger->new(%data);
        $schema->add_trigger($trigger);
    }

    #
    # Procedures
    #
    @nodes = $xp->findnodes(
       '/sqlf:schema/sqlf:procedure|/sqlf:schema/sqlf:procedures/sqlf:procedure'
    );
    foreach (@nodes) {
        my %data = get_tagfields($xp, $_, "sqlf:",
        qw/name sql parameters owner comments extra/
        );
        my $procedure = Procedure->new(%data);
        $schema->add_procedure($procedure);
    }

    return 1;
}

# -------------------------------------------------------------------
sub get_tagfields {
#
# get_tagfields XP, NODE, NAMESPACE => qw/TAGNAMES/;
# get_tagfields $node, "sqlf:" => qw/name type fields reference/;
#
# Returns hash of data.
# TODO - Add handling of an explicit NULL value.
#

    my ($xp, $node, @names) = @_;
    my (%data, $ns);
    foreach (@names) {
        if ( m/:$/ ) { $ns = $_; next; }  # Set def namespace
        my $thisns = (s/(^.*?:)// ? $1 : $ns);

        my $is_attrib = m/^(sql|comments|action|extra)$/ ? 0 : 1;

        my $attrib_path = "\@$_";
        my $tag_path    = "$thisns$_";
        if ( my $found = $xp->find($attrib_path,$node) ) {
            $data{$_} = "".$found->to_literal;
            warn "Use of '$_' as an attribute is depricated."
                ." Use a child tag instead."
                ." To convert your file to the new version see the Docs.\n"
                unless $is_attrib;
#            debug "Got $_=".( defined $data{ $_ } ? $data{ $_ } : 'UNDEF' );
        }
        elsif ( $found = $xp->find($tag_path,$node) ) {
            if ($_ eq "extra") {
                my %extra;
                foreach ( $found->pop->getAttributes ) {
                    $extra{$_->getName} = $_->getData;
                }
                $data{$_} = \%extra;
            }
            else {
                $data{$_} = "".$found->to_literal;
            }
            warn "Use of '$_' as a child tag is depricated."
                ." Use an attribute instead."
                ." To convert your file to the new version see the Docs.\n"
                if $is_attrib;
#            debug "Got $_=".( defined $data{ $_ } ? $data{ $_ } : 'UNDEF' );
        }
    }

    return wantarray ? %data : \%data;
}
}

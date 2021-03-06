use MooseX::Declare;
role SQL::Translator::Producer::SQL::MySQL {
    use SQL::Translator::Constants qw(:sqlt_types :sqlt_constants);
    use SQL::Translator::Types qw(Column Constraint Index Table View);
    my $DEFAULT_MAX_ID_LENGTH = 64;
    my %used_names;

    #
    # Use only lowercase for the keys (e.g. "long" and not "LONG")
    #
    my %translate  = (
        #
        # Oracle types
        #
        varchar2   => 'varchar',
        long       => 'text',
        clob       => 'longtext',
    
        #
        # Sybase types
        #
        int        => 'integer',
        money      => 'float',
        real       => 'double',
        comment    => 'text',
        bit        => 'tinyint',
    
        #
        # Access types
        #
        'long integer' => 'integer',
        'text'         => 'text',
        'datetime'     => 'datetime',
    
        #
        # PostgreSQL types
        #
        bytea => 'BLOB',
    );
    
    #
    # Column types that do not support lenth attribute
    #
    my @no_length_attr = qw/ date time timestamp datetime year /;
    
    method preprocess_schema($schema) {
#        my ($schema) = @_;
    
        # extra->{mysql_table_type} used to be the type. It belongs in options, so
        # move it if we find it. Return Engine type if found in extra or options
        # Similarly for mysql_charset and mysql_collate
        my $extra_to_options = sub {
          my ($table, $extra_name, $opt_name) = @_;
    
          my $extra = $table->extra;
    
          my $extra_type = delete $extra->{$extra_name};
    
          # Now just to find if there is already an Engine or Type option...
          # and lets normalize it to ENGINE since:
          #
          # The ENGINE table option specifies the storage engine for the table. 
          # TYPE is a synonym, but ENGINE is the preferred option name.
          #
    
          # We have to use the hash directly here since otherwise there is no way 
          # to remove options.
          my $options = ( $table->{options} ||= []);
    
          # If multiple option names, normalize to the first one
          if (ref $opt_name) {
            OPT_NAME: for ( @$opt_name[1..$#$opt_name] ) {
              for my $idx ( 0..$#{$options} ) {
                my ($key, $value) = %{ $options->[$idx] };
                
                if (uc $key eq $_) {
                  $options->[$idx] = { $opt_name->[0] => $value };
                  last OPT_NAME;
                }
              }
            }
            $opt_name = $opt_name->[0];
    
          }
    
    
          # This assumes that there isn't both a Type and an Engine option.
          OPTION:
          for my $idx ( 0..$#{$options} ) {
            my ($key, $value) = %{ $options->[$idx] };
    
            next unless uc $key eq $opt_name;
         
            # make sure case is right on option name
            delete $options->[$idx]{$key};
            return $options->[$idx]{$opt_name} = $value || $extra_type;
    
          }
      
          if ($extra_type) {
            push @$options, { $opt_name => $extra_type };
            return $extra_type;
          }
    
        };
    
        # Names are only specific to a given schema
        my %used_names = ();
    
        #
        # Work out which tables need to be InnoDB to support foreign key
        # constraints. We do this first as we need InnoDB at both ends.
        #
        foreach my $table ( $schema->get_tables ) {
          
            $extra_to_options->($table, 'mysql_table_type', ['ENGINE', 'TYPE'] );
            $extra_to_options->($table, 'mysql_charset', 'CHARACTER SET' );
            $extra_to_options->($table, 'mysql_collate', 'COLLATE' );
    
            foreach my $c ( $table->get_constraints ) {
                next unless $c->type eq FOREIGN_KEY;
    
                # Normalize constraint names here.
                my $c_name = $c->name;
                # Give the constraint a name if it doesn't have one, so it doens't feel
                # left out
                $c_name   = $table->name . '_fk' unless length $c_name;
                
                $c->name( $self->next_unused_name($c_name) );
    
                for my $meth (qw/table reference_table/) {
                    my $table = $schema->get_table($c->$meth) || next;
                    # This normalizes the types to ENGINE and returns the value if its there
                    next if $extra_to_options->($table, 'mysql_table_type', ['ENGINE', 'TYPE']); 
#                    $table->options( [ { ENGINE => 'InnoDB' } ] );
                }
            } # foreach constraints
    
            my %map = ( mysql_collate => 'collate', mysql_charset => 'character set');
            foreach my $f ( $table->get_fields ) {
              my $extra = $f->extra;
              for (keys %map) {
                $extra->{$map{$_}} = delete $extra->{$_} if exists $extra->{$_};
              }
    
              my @size = $f->size;
              if ( !$size[0] && $f->data_type =~ /char$/ ) {
                $f->size( (255) );
              }
            }
    
        }
    }
    
    method produce {
        my $translator = $self->translator;
        my $DEBUG = 0;#     = $translator->debug;
        #local %used_names;
        my $no_comments    = $translator->no_comments;
        my $add_drop_table = $translator->add_drop_table;
        my $schema         = $translator->schema;
        my $show_warnings  = $translator->show_warnings || 0;
        my $producer_args  = $translator->producer_args;
        my $mysql_version  = $translator->engine_version ($producer_args->{mysql_version}, 'perl') || 0;
        my $max_id_length  = $producer_args->{mysql_max_id_length} || $DEFAULT_MAX_ID_LENGTH;
    
        my ($qt, $qf, $qc) = ('','', '');
        $qt = '`' if $translator->quote_table_names;
        $qf = '`' if $translator->quote_field_names;
    
        #debug("PKG: Beginning production\n");
        %used_names = ();
        my $create = ''; 
        $create .= $self->header_comment unless ($no_comments);
        # \todo Don't set if MySQL 3.x is set on command line
        my @create = "SET foreign_key_checks=0";
    
        $self->preprocess_schema($schema);
    
        #
        # Generate sql
        #
        my @table_defs =();
        
        for my $table ( $schema->get_tables ) {
    #        print $table->name, "\n";
            push @table_defs, $self->create_table($table, 
                                           { add_drop_table    => $add_drop_table,
                                             show_warnings     => $show_warnings,
                                             no_comments       => $no_comments,
                                             quote_table_names => $qt,
                                             quote_field_names => $qf,
                                             max_id_length     => $max_id_length,
                                             mysql_version     => $mysql_version
                                             });
        }
    
        if ($mysql_version >= 5.000001) {
          for my $view ( $schema->get_views ) {
            push @table_defs, $self->create_view($view,
                                           { add_replace_view  => $add_drop_table,
                                             show_warnings     => $show_warnings,
                                             no_comments       => $no_comments,
                                             quote_table_names => $qt,
                                             quote_field_names => $qf,
                                             max_id_length     => $max_id_length,
                                             mysql_version     => $mysql_version
                                             });
          }
        }
    
    
        #warn "@table_defs\n";
        push @table_defs, "SET foreign_key_checks=1";
        return wantarray ? ($create ? $create : (), @create, @table_defs) : ($create . join('', map { $_ ? "$_;\n\n" : () } (@create, @table_defs)));
    }
    
    method create_view($view, $options) {
        my $qt = $options->{quote_table_names} || '';
        my $qf = $options->{quote_field_names} || '';
    
        my $view_name = $view->name;
        #debug("PKG: Looking at view '${view_name}'\n");
    
        # Header.  Should this look like what mysqldump produces?
        my $create = '';
        $create .= "--\n-- View: ${qt}${view_name}${qt}\n--\n" unless $options->{no_comments};
        $create .= 'CREATE';
        $create .= ' OR REPLACE' if $options->{add_replace_view};
        $create .= "\n";
    
        my $extra = $view->extra;
        # ALGORITHM
        if( exists($extra->{mysql_algorithm}) && defined(my $algorithm = $extra->{mysql_algorithm}) ){
          $create .= "   ALGORITHM = ${algorithm}\n" if $algorithm =~ /(?:UNDEFINED|MERGE|TEMPTABLE)/i;
        }
        # DEFINER
        if( exists($extra->{mysql_definer}) && defined(my $user = $extra->{mysql_definer}) ){
          $create .= "   DEFINER = ${user}\n";
        }
        # SECURITY
        if( exists($extra->{mysql_security}) && defined(my $security = $extra->{mysql_security}) ){
          $create .= "   SQL SECURITY ${security}\n" if $security =~ /(?:DEFINER|INVOKER)/i;
        }
    
        #Header, cont.
        $create .= "  VIEW ${qt}${view_name}${qt}";
    
        if( my @fields = $view->fields ){
          my $list = join ', ', map { "${qf}${_}${qf}"} @fields;
          $create .= " ( ${list} )";
        }
        if( my $sql = $view->sql ){
          $create .= " AS (\n    ${sql}\n  )";
        }
    #    $create .= "";
        return $create;
    }
    
    method create_table($table, $options) {
#        my ($table, $options) = @_;
    
        my $qt = $options->{quote_table_names} || '';
        my $qf = $options->{quote_field_names} || '';
    
        my $table_name = $self->quote_table_name($table->name, $qt);
        #debug("PKG: Looking at table '$table_name'\n");
    
        #
        # Header.  Should this look like what mysqldump produces?
        #
        my $create = '';
        my $drop;
        $create .= "--\n-- Table: $table_name\n--\n" unless $options->{no_comments};
        $drop = qq[DROP TABLE IF EXISTS $table_name] if $options->{add_drop_table};
        $create .= "CREATE TABLE $table_name (\n";
    
        #
        # Fields
        #
        my @field_defs;
        for my $field ( $table->get_fields ) {
            push @field_defs, $self->create_field($field, $options);
        }
    
        #
        # Indices
        #
        my @index_defs;
        my %indexed_fields;
        for my $index ( $table->get_indices ) {
            push @index_defs, $self->create_index($index, $options);
            $indexed_fields{ $_ } = 1 for $index->fields;
        }
    
        #
        # Constraints -- need to handle more than just FK. -ky
        #
        my @constraint_defs;
        my @constraints = $table->get_constraints;
        for my $c ( @constraints ) {
            my $constr = $self->create_constraint($c, $options); 
            push @constraint_defs, $constr if($constr); #use Data::Dumper; warn Dumper($c->columns) if $constr =~ /^CONSTRAINT/; # unless $c->fields;
            next unless $c->fields;
 
            unless ( $indexed_fields{ ($c->fields())[0] } || $c->type ne FOREIGN_KEY ) {
                 push @index_defs, "INDEX ($qf" . ($c->fields())[0] . "$qf)";
                 $indexed_fields{ ($c->fields())[0] } = 1;
            }
        }

        $create .= join(",\n", map { "  $_" } 
                        @field_defs, @index_defs, @constraint_defs
                        );

        #
        # Footer
        #
        $create .= "\n)";
        $create .= $self->generate_table_options($table, $options) || '';
    #    $create .= ";\n\n";
    
        return $drop ? ($drop,$create) : $create;
    }
    
    method quote_table_name(Str $table_name, Str $qt) {
      $table_name =~ s/\./$qt.$qt/g;
    
      return "$qt$table_name$qt";
    }
    
    method generate_table_options(Table $table, $options?) { 
      my $create;
    
      my $table_type_defined = 0;
      my $qf               = $options->{quote_field_names} ||= '';
      my $charset          = $table->extra->{'mysql_charset'};
      my $collate          = $table->extra->{'mysql_collate'};
      my $union            = undef;

      for my $t1_option_ref ($table->options) {
        my($key, $value) = %{$t1_option_ref};
        $table_type_defined = 1
          if uc $key eq 'ENGINE' or uc $key eq 'TYPE';
        if (uc $key eq 'CHARACTER SET') {
          $charset = $value;
          next;
        } elsif (uc $key eq 'COLLATE') {
          $collate = $value;
          next;
        } elsif (uc $key eq 'UNION') {
          $union = "($qf". join("$qf, $qf", @$value) ."$qf)";
          next;
        }
        $create .= " $key=$value";
      }
    
      my $mysql_table_type = $table->extra->{'mysql_table_type'};
      $create .= " ENGINE=$mysql_table_type"
        if $mysql_table_type && !$table_type_defined;
      my $comments         = $table->comments;
    
      $create .= " DEFAULT CHARACTER SET $charset" if $charset;
      $create .= " COLLATE $collate" if $collate;
      $create .= " UNION=$union" if $union;
      $create .= qq[ comment='$comments'] if $comments;
      return $create;
    }
    
    method create_field($field, $options?) {
        my $qf = $options->{quote_field_names} ||= '';
    
        my $field_name = $field->name;
        #debug("PKG: Looking at field '$field_name'\n");
        my $field_def = "$qf$field_name$qf";
    
        # data type and size
        my $data_type = $field->data_type;
        my @size      = $field->size;
        my %extra     = $field->extra;
        my $list      = $extra{'list'} || [];
        # \todo deal with embedded quotes
        my $commalist = join( ', ', map { qq['$_'] } @$list );
        my $charset = $extra{'mysql_charset'};
        my $collate = $extra{'mysql_collate'};
    
        my $mysql_version = $options->{mysql_version} || 0;
        #
        # Oracle "number" type -- figure best MySQL type
        #
        if ( lc $data_type eq 'number' ) {
            # not an integer
            if ( scalar @size > 1 ) {
                $data_type = 'double';
            }
            elsif ( $size[0] && $size[0] >= 12 ) {
                $data_type = 'bigint';
            }
            elsif ( $size[0] && $size[0] <= 1 ) {
                $data_type = 'tinyint';
            }
            else {
                $data_type = 'int';
            }
        }
        #
        # Convert a large Oracle varchar to "text"
        # (not necessary as of 5.0.3 http://dev.mysql.com/doc/refman/5.0/en/char.html)
        #
        elsif ( $data_type =~ /char/i && $size[0] > 255 ) {
            unless ($size[0] <= 65535 && $mysql_version >= 5.000003 ) {
                $data_type = 'text';
                @size      = ();
            }
        }
        elsif ( $data_type =~ /boolean/i ) {
            if ($mysql_version >= 4) {
                $data_type = 'boolean';
            } else {
                $data_type = 'enum';
                $commalist = "'0','1'";
            }
        }
#        elsif ( exists $translate{ lc $data_type } ) {
#            $data_type = $translate{ lc $data_type };
#        }
    
        @size = () if $data_type =~ /(text|blob)/i;
    
        if ( $data_type =~ /(double|float)/ && scalar @size == 1 ) {
            push @size, '0';
        }
    
        $field_def .= " $data_type";
    
        if ( lc($data_type) eq 'enum' || lc($data_type) eq 'set') {
            $field_def .= '(' . $commalist . ')';
        }
        elsif ( 
            defined $size[0] && $size[0] > 0 
            && 
            ! grep lc($data_type) eq $_, @no_length_attr  
        ) {
            $field_def .= '(' . join( ', ', @size ) . ')';
        }
    
        # char sets
        $field_def .= " CHARACTER SET $charset" if $charset;
        $field_def .= " COLLATE $collate" if $collate;
    
        # MySQL qualifiers
        for my $qual ( qw[ binary unsigned zerofill ] ) {
            my $val = $extra{ $qual } || $extra{ uc $qual } or next;
            $field_def .= " $qual";
        }
        for my $qual ( 'character set', 'collate', 'on update' ) {
            my $val = $extra{ $qual } || $extra{ uc $qual } or next;
            $field_def .= " $qual $val";
        }
    
        # Null?
        $field_def .= ' NOT NULL' unless $field->is_nullable;
    
        # Default?  XXX Need better quoting!
        my $default = $field->default_value;

#        if ( defined $default ) {
#            SQL::Translator::Producer->_apply_default_value(
#              \$field_def,
#              $default, 
#              [
#                'NULL'       => \'NULL',
#              ],
#            );
#        }
    
        if ( my $comments = $field->comments ) {
            $field_def .= qq[ comment '$comments'];
        }
    
        # auto_increment?
        $field_def .= " auto_increment" if $field->is_auto_increment;
    
        return $field_def;
    }
    
    method alter_create_index(Index $index, $options?) {
        my $qt = $options->{quote_table_names} || '';
        my $qf = $options->{quote_field_names} || '';
    
        return join( ' ',
                     'ALTER TABLE',
                     $qt.$index->table->name.$qt,
                     'ADD',
                     create_index(@_)
                     );
    }
    
    method create_index($index, $options?) {
#        my ( $index, $options ) = @_;
    
        my $qf = $options->{quote_field_names} || '';
    
        return join(
            ' ',
            map { $_ || () }
            lc $index->type eq 'normal' ? 'INDEX' : $index->type . ' INDEX',
            $index->name
            ? (
                $self->truncate_id_uniquely(
                    $index->name,
                    $options->{max_id_length} || $DEFAULT_MAX_ID_LENGTH
                )
              )
            : '',
            '(' . $qf . join( "$qf, $qf", $index->fields ) . $qf . ')'
        );
    }
    
    method alter_drop_index(Index $index, $options?) {
        my $qt = $options->{quote_table_names} || '';
        my $qf = $options->{quote_field_names} || '';
    
        return join( ' ', 
                     'ALTER TABLE',
                     $qt.$index->table->name.$qt,
                     'DROP',
                     'INDEX',
                     $index->name || $index->fields
                     );
    
    }
    
    method alter_drop_constraint(Constraint $c, $options?) {
        my $qt      = $options->{quote_table_names} || '';
        my $qc      = $options->{quote_field_names} || '';
    
        my $out = sprintf('ALTER TABLE %s DROP %s %s',
                          $qt . $c->table->name . $qt,
                          $c->type eq FOREIGN_KEY ? $c->type : "INDEX",
                          $qc . $c->name . $qc );
    
        return $out;
    }
    
    method alter_create_constraint($index, $options?) {
        my $qt = $options->{quote_table_names} || '';
        return join( ' ',
                     'ALTER TABLE',
                     $qt.$index->table->name.$qt,
                     'ADD',
                     $self->create_constraint(@_) );
    }
    
    method create_constraint(Constraint $c, $options?) {
        my $qf      = $options->{quote_field_names} || '';
        my $qt      = $options->{quote_table_names} || '';
        my $leave_name      = $options->{leave_name} || undef;
    
        my @fields = $c->fields or return;
    
        if ( $c->type eq PRIMARY_KEY ) {
            return 'PRIMARY KEY (' . $qf . join("$qf, $qf", @fields). $qf . ')';
        }
        elsif ( $c->type eq UNIQUE ) {
            return
            'UNIQUE '. 
                (defined $c->name ? $qf.$self->truncate_id_uniquely( $c->name, $options->{max_id_length} || $DEFAULT_MAX_ID_LENGTH ).$qf.' ' : '').
                '(' . $qf . join("$qf, $qf", @fields). $qf . ')';
        }
        elsif ( $c->type eq FOREIGN_KEY ) {
            #
            # Make sure FK field is indexed or MySQL complains.
            #
            my $table = $c->table;
            my $c_name = $self->truncate_id_uniquely( $c->name, $options->{max_id_length} || $DEFAULT_MAX_ID_LENGTH );
    
            my $def = join(' ', 
                           map { $_ || () } 
                             'CONSTRAINT', 
                             $qf . $c_name . $qf, 
                             'FOREIGN KEY'
                          );
    
    
            $def .= ' ('.$qf . join( "$qf, $qf", @fields ) . $qf . ')';

            $def .= ' REFERENCES ' . $qt . $c->reference_table . $qt;
            my @rfields = map { $_ || () } $c->reference_fields;

            unless ( @rfields ) {
                my $rtable_name = $c->reference_table;
                if ( my $ref_table = $table->schema->get_table( $rtable_name ) ) {
                    push @rfields, $ref_table->primary_key;
                }
                else {
                    warn "Can't find reference table '$rtable_name' " .
                        "in schema\n" if $options->{show_warnings};
                }
            }
    
            if ( @rfields ) {
                $def .= ' (' . $qf . join( "$qf, $qf", @rfields ) . $qf . ')';
            }
            else {
                warn "FK constraint on " . $table->name . '.' .
                    join('', @fields) . " has no reference fields\n" 
                    if $options->{show_warnings};
            }
    
            if ( $c->match_type ) {
                $def .= ' MATCH ';
                $def .= ( $c->match_type =~ /full/i ) ? 'FULL' : 'PARTIAL';
            }
#            if ( $c->on_delete ) {
#                $def .= ' ON DELETE '.join( ' ', $c->on_delete );
#            }
    
#            if ( $c->on_update ) {
#                $def .= ' ON UPDATE '.join( ' ', $c->on_update );
#            }
            return $def;
        }
    
        return undef;
    }
    
    method alter_table(Str $to_table, $options?) {
        my $qt = $options->{quote_table_names} || '';
    
        my $table_options = $self->generate_table_options($to_table, $options) || '';
        my $out = sprintf('ALTER TABLE %s%s',
                          $qt . $to_table->name . $qt,
                          $table_options);
    
        return $out;
    }
    
    method rename_field(@args) { alter_field(@args) }
    method alter_field(Str $from_field, Str $to_field, $options?) {
        my $qf = $options->{quote_field_names} || '';
        my $qt = $options->{quote_table_names} || '';
    
        my $out = sprintf('ALTER TABLE %s CHANGE COLUMN %s %s',
                          $qt . $to_field->table->name . $qt,
                          $qf . $from_field->name . $qf,
                          $self->create_field($to_field, $options));
    
        return $out;
    }
    
    method add_field(Str $new_field, $options?) {
        my $qt = $options->{quote_table_names} || '';
    
        my $out = sprintf('ALTER TABLE %s ADD COLUMN %s',
                          $qt . $new_field->table->name . $qt,
                          create_field($new_field, $options));
    
        return $out;
    
    }
    
    method drop_field(Str $old_field, $options?) {
        my $qf = $options->{quote_field_names} || '';
        my $qt = $options->{quote_table_names} || '';
        
        my $out = sprintf('ALTER TABLE %s DROP COLUMN %s',
                          $qt . $old_field->table->name . $qt,
                          $qf . $old_field->name . $qf);
    
        return $out;
        
    }
    
    method batch_alter_table($table, $diff_hash, $options?) {
      # InnoDB has an issue with dropping and re-adding a FK constraint under the 
      # name in a single alter statment, see: http://bugs.mysql.com/bug.php?id=13741
      #
      # We have to work round this.
    
      my %fks_to_alter;
      my %fks_to_drop = map {
        $_->type eq FOREIGN_KEY 
                  ? ( $_->name => $_ ) 
                  : ( )
      } @{$diff_hash->{alter_drop_constraint} };
    
      my %fks_to_create = map {
        if ( $_->type eq FOREIGN_KEY) {
          $fks_to_alter{$_->name} = $fks_to_drop{$_->name} if $fks_to_drop{$_->name};
          ( $_->name => $_ );
        } else { ( ) }
      } @{$diff_hash->{alter_create_constraint} };
    
      my @drop_stmt;
      if (scalar keys %fks_to_alter) {
        $diff_hash->{alter_drop_constraint} = [
          grep { !$fks_to_alter{$_->name} } @{ $diff_hash->{alter_drop_constraint} }
        ];
    
        @drop_stmt = batch_alter_table($table, { alter_drop_constraint => [ values %fks_to_alter ] }, $options);
    
      }
    
      my @stmts = map {
        if (@{ $diff_hash->{$_} || [] }) {
          my $meth = __PACKAGE__->can($_) or die __PACKAGE__ . " cant $_";
          map { $meth->( (ref $_ eq 'ARRAY' ? @$_ : $_), $options ) } @{ $diff_hash->{$_} }
        } else { () }
      } qw/rename_table
           alter_drop_constraint
           alter_drop_index
           drop_field
           add_field
           alter_field
           rename_field
           alter_create_index
           alter_create_constraint
           alter_table/;
    
      # rename_table makes things a bit more complex
      my $renamed_from = "";
      $renamed_from = $diff_hash->{rename_table}[0][0]->name
        if $diff_hash->{rename_table} && @{$diff_hash->{rename_table}};
    
      return unless @stmts;
      # Just zero or one stmts. return now
      return (@drop_stmt,@stmts) unless @stmts > 1;
    
      # Now strip off the 'ALTER TABLE xyz' of all but the first one
    
      my $qt = $options->{quote_table_names} || '';
      my $table_name = $qt . $table->name . $qt;
    
    
      my $re = $renamed_from 
             ? qr/^ALTER TABLE (?:\Q$table_name\E|\Q$qt$renamed_from$qt\E) /
                : qr/^ALTER TABLE \Q$table_name\E /;
    
      my $first = shift  @stmts;
      my ($alter_table) = $first =~ /($re)/;
    
      my $padd = " " x length($alter_table);
    
      return @drop_stmt, join( ",\n", $first, map { s/$re//; $padd . $_ } @stmts);
    
    }
    
    method drop_table(Str $table, $options?) {
        my $qt = $options->{quote_table_names} || '';
    
      # Drop (foreign key) constraints so table drops cleanly
      my @sql = batch_alter_table($table, { alter_drop_constraint => [ grep { $_->type eq 'FOREIGN KEY' } $table->get_constraints ] }, $options);
    
      return (@sql, "DROP TABLE $qt$table$qt");
    #  return join("\n", @sql, "DROP TABLE $qt$table$qt");
    
    }
    
    method rename_table(Str $old_table, Str $new_table, $options?) {
      my $qt = $options->{quote_table_names} || '';
    
      return "ALTER TABLE $qt$old_table$qt RENAME TO $qt$new_table$qt";
    }
    
    method next_unused_name($name?) {
#      my $name       = shift || '';
      if ( !defined($used_names{$name}) ) {
        $used_names{$name} = $name;
        return $name;
      }
    
      my $i = 1;
      while ( defined($used_names{$name . '_' . $i}) ) {
        ++$i;
      }
      $name .= '_' . $i;
      $used_names{$name} = $name;
      return $name;
    }

    method header_comment($producer?, $comment_char?) {
	$producer ||= caller;
	my $now = scalar localtime;
        my $DEFAULT_COMMENT = '-- ';

	$comment_char = $DEFAULT_COMMENT
	    unless defined $comment_char;

	my $header_comment =<<"HEADER_COMMENT";
	    ${comment_char}
	    ${comment_char}Created by $producer
	    ${comment_char}Created on $now
	    ${comment_char}
HEADER_COMMENT

	# Any additional stuff passed in
	for my $additional_comment (@_) {
	    $header_comment .= "${comment_char}${additional_comment}\n";
	}

	return $header_comment;
    }

    use constant COLLISION_TAG_LENGTH => 8;

    method truncate_id_uniquely(Str $desired_name, Int $max_symbol_length) {
        use Digest::SHA1 qw(sha1_hex);
        return $desired_name
          unless defined $desired_name && length $desired_name > $max_symbol_length;

        my $truncated_name = substr $desired_name, 0,
          $max_symbol_length - COLLISION_TAG_LENGTH - 1;

        # Hex isn't the most space-efficient, but it skirts around allowed
        # charset issues
        my $digest = sha1_hex($desired_name);
        my $collision_tag = substr $digest, 0, COLLISION_TAG_LENGTH;

        return $truncated_name
             . '_'
             . $collision_tag;
    }
}

use MooseX::Declare;
role SQL::Translator::Parser::DBI::MySQL {
    use MooseX::Types::Moose qw(HashRef Str);
    use SQL::Translator::Types qw(View);

    method _get_view_sql(View $view) {
        #my ($sql) = $self->dbh->selectrow_array('');
        #return $sql;
        return '';
    }

    method _is_auto_increment(HashRef $column_info) {
        return $column_info->{mysql_is_auto_increment};
    }

    method _column_default_value(HashRef $column_info) {
        my $default_value = $column_info->{COLUMN_DEF};
        $default_value =~ s/::.*$// if defined $default_value;

        return $default_value;
    }
}

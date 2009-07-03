package SQL::Translator::Parser;
use namespace::autoclean;
use Moose;
use MooseX::Types::Moose qw(Str);
use SQL::Translator::Types qw(DBIHandle);

my $apply_role_dbi = sub {
    my $self = shift;
    my $class = __PACKAGE__ . '::DBI';
    Class::MOP::load_class($class);
    $class->meta->apply($self);
    $self->_subclass();
};

my $apply_role_ddl = sub { };

has 'dbh' => (
    isa => DBIHandle,
    is => 'ro',
    predicate => 'has_dbh',
    trigger => $apply_role_dbi,
);

has 'filename' => (
    isa => Str,
    is => 'ro',
    predicate => 'has_ddl',
    trigger => $apply_role_ddl,
);

sub BUILD {}

sub parse {
    my $self = shift;
    my $schema = SQL::Translator::Object::Schema->new({ name => $self->schema_name });
    $self->_add_tables($schema);
    $schema;
}

__PACKAGE__->meta->make_immutable;

1;

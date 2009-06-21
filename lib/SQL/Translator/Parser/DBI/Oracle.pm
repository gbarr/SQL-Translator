package SQL::Translator::Parser::DBI::Oracle;
use Moose;
use SQL::Translator::Types qw(Schema);
with 'SQL::Translator::Parser::DBI::Dialect';

has 'schema' => (is => 'ro', isa => Schema, default => sub { SQL::Translator::Object::Schema->new( { name => '' }) });

1;

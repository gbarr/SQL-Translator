use MooseX::Declare;
class SQL::Translator::Object with SQL::Translator::Object::Compat {
    use Tie::IxHash;
    use MooseX::MultiMethods;
    use MooseX::Types::Moose qw(Any ArrayRef HashRef Str);

    has '_comments' => (
        traits => ['Array'],
        isa => ArrayRef,
        coerce => 1,
        handles => {
            _comments           => 'elements',
            add_comment         => 'push',
            remove_last_comment => 'pop',
        },
        default => sub { [] },
    );

    has '_options' => (
        traits => ['Array'],
        isa => ArrayRef,
        coerce => 1,
        handles => {
            _options           => 'elements',
            add_option         => 'push',
            remove_last_option => 'pop',
        },
        default => sub { [] },
    );

    has '_extra' => (
        traits => ['Hash'],
        is => 'rw',
        isa => HashRef,
        handles => {
            exists_extra => 'exists',
            extra_ids    => 'keys',
            get_extras   => 'values',
            get_extra    => 'get',
            add_extra    => 'set',
        },
        default => sub { {} },
    );

    has '_error' => (
        is => 'rw',
        isa => Str
    );

    multi method comments(Str $comment) { $self->add_comment($comment); $self->comments }
    multi method comments(ArrayRef $comments) { $self->add_comment($_) for @$comments; $self->comments }
    multi method comments { wantarray ? $self->_comments : join "\n", $self->_comments }

    multi method options(Str $option) { $self->add_option($option); $self->options }
    multi method options(ArrayRef $options) { $self->add_option($_) for @$options; $self->options }
    multi method options { wantarray ? $self->_options : $self->_options }

    multi method extra(Str $extra) { $self->get_extra($extra) }
    multi method extra(HashRef $extra) { $self->add_extra($_, $extra->{$_}) for keys %$extra; $self->extra }
    multi method extra { wantarray ? %{$self->_extra} : $self->_extra }

    around BUILDARGS(ClassName $self: @args) {
        my $args = $self->$orig(@args);

        $args->{_comments} = delete $args->{comments} || [];
        $args->{_options} = delete $args->{options} || [];
        $args->{_extra} = delete $args->{extra} || {};

        return $args;
     }
}

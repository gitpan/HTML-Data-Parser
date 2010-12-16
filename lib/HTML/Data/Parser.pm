package HTML::Data::Parser;

use base qw[RDF::Trine::Parser];

use HTML::HTML5::Parser;
use RDF::Trine;
use RDF::RDFa::Parser 1.093;
use Scalar::Util qw(blessed reftype);
use XML::LibXML;

our $VERSION = '0.001';

BEGIN
{
	$RDF::Trine::Parser::parser_names{ 'rdfa' } = __PACKAGE__;
}

sub new
{
	my ($class, %options) = @_;
	
	my $self = bless {
		dom_parser         => 'html5',
		parse_grddl        => 0,
		parse_rdfa         => 1,
		parse_microdata    => undef,
		parse_microformats => undef,
		parse_n3           => undef,
		on_error           => 'warn',
		%options,
		}, $class;
	
	return $self;
}

sub parse
{
	my ($self, $base, $string, $handler) = @_;
	
	$self->{'_document_context'} = {};
	
	return unless reftype($handler) eq 'CODE';
	
	my $modules = {
		grddl        => ['XML::GRDDL'],
		rdfa         => ['RDF::RDFa::Parser'],
		microdata    => ['HTML::HTML5::Microdata::Parser'],
		microformats => ['HTML::Microformats'],
		n3           => ['HTML::Embedded::Turtle'],
		};

	my $dom;
	if (blessed($string) and $string->isa('XML::LibXML::Document'))
	{
		$dom = $string;
		$self->{'options_rdfa_default'} = RDF::RDFa::Parser::Config->new('xhtml'); 
	}
	elsif ($self->{dom_parser} =~ /^(xml|xhtml|x)$/i)
	{
		$dom = XML::LibXML->new->parse_string("$string");
		$self->{'options_rdfa_default'} = RDF::RDFa::Parser::Config->new('xhtml'); 
	}
	else
	{
		$dom = HTML::HTML5::Parser->new->parse_string("$string");
		$self->{'options_rdfa_default'} = RDF::RDFa::Parser::Config->new('html'); 
	}

	foreach my $type (qw[rdfa grddl microdata microformats turtle])
	{
		my $should_parse = $self->{"parse_${type}"};
		unless (defined $should_parse and !$should_parse)
		{
			local $@ = undef;
			my @module = @{$modules->{$type}};
			eval join(' ', 'require', @module).';'
				unless $module[0] eq 'RDF::RDFa::Parser';
			if (! $@)
			{
				my $sub = "parse_${type}";
				$self->$sub($base, $dom, $handler);
			}
			elsif (defined $should_parse)
			{
				$self->handle_error("Could not require @module: ".$@);
			}
		}
	}
}

sub handle_triple
{
	my ($self, $handler, $g, $st) = @_;
	my @nodes = $st->nodes;
	
	if ($self->{named_graphs} and $g)
	{
		$st = RDF::Trine::Statement->new(
			@nodes[0..2],
			RDF::Trine::Node::Resource->new($g),
			);
	}
	elsif (defined $nodes[3])
	{
		$st = RDF::Trine::Statement->new(@nodes[0..2]);
	}
	
	$handler->($st);
}

sub handle_error
{
	my ($self, $err) = @_;
	if (reftype($self->{on_error}) eq 'CODE')
	{
		$self->{on_error}->($err);
	}
	elsif ($self->{on_error} =~ /^warn$/i)
	{
		warn $err;
	}
	elsif ($self->{on_error} =~ /^die$/i)
	{
		die $err;
	}
}

sub parse_rdfa
{
	my ($self, $base, $dom, $handler) = @_;
	my $parser = RDF::RDFa::Parser->new($dom, $base, $self->{'options_rdfa'}||$self->{'options_rdfa_default'});
	$parser->set_callbacks({
		ontriple => sub {
			my ($p, $e, $st) = @_;
			$self->handle_triple($handler, "${base}#graph/rdfa", $st);
			},
		onerror => sub {
			my ($p, $l, $c, $e) = @_;
			$self->handle_error("RDF::RDFa::Parser Error: ".$e);
			},
		});
	$parser->consume;
	$self->{'_document_context'}->{'RDFA'} = $parser; # used by parse_turtle
}

sub parse_microdata
{
	my ($self, $base, $dom, $handler) = @_;
	my $parser = HTML::HTML5::Microdata::Parser->new($dom, $base, $self->{'options_microdata'});
	$parser->set_callbacks({
		ontriple => sub {
			my ($p, $e, $st) = @_;
			$self->handle_triple($handler, "${base}#graph/microdata", $st);
			},
		});
	$parser->consume;
}

sub parse_n3
{
	my ($self, $base, $dom, $handler) = @_;
	
	my $het;
	if ($self->{'_document_context'}->{'RDFA'})
	{
		# cheat for speed
		$het = bless {
			rdfa_parser => $self->{'_document_context'}->{'RDFA'},
			dom         => $self->{'_document_context'}->{'RDFA'}->dom,
			base_uri    => $self->{'_document_context'}->{'RDFA'}->uri,
			}, 'HTML::Embedded::Turtle';
		$het->_find_endorsed;
		$het->_extract_graphs;
	}
	else
	{
		$het = HTML::Embedded::Turtle->new($dom->toString, $base, {markup=>'xhtml'});
	}
	
	my $model = $het->union_graph;
	$model->as_stream->each(sub {
		my ($st) = @_;
		$self->handle_triple($handler, "${base}#graph/n3", $st);
		});
}

sub parse_microformats
{
	my ($self, $base, $dom, $handler) = @_;
	
	my $doc   = HTML::Microformats->new_document($dom, $base)->assume_all_profiles;
	my $model = $doc->model;
	$model->as_stream->each(sub {
		my ($st) = @_;
		$self->handle_triple($handler, "${base}#graph/microformats", $st);
		});
}

sub parse_grddl
{
	my ($self, $base, $dom, $handler) = @_;
	
	$self->{'_instance_context'}->{'GRDDL'} = XML::GRDDL->new;
	my $model = $self->{'_instance_context'}->{'GRDDL'}->data($dom, $base);
	$model->as_stream->each(sub {
		my ($st) = @_;
		$self->handle_triple($handler, "${base}#graph/grddl", $st);
		});
}

1;

__END__

=head1 NAME

HTML::Data::Parser - parses data embedded in HTML

=head1 SYNOPSIS

Be like Google! Google Rich Snippets supports RDFa, Microdata and Microformats,
so why shouldn't you?

  use RDF::Trine;
  use HTML::Data::Parser;
  
  my $parser = HTML::Data::Parser->new(
    parse_rdfa         => 1,
    parse_grddl        => 0,
    parse_microformats => undef,
    parse_microdata    => undef,
    parse_n3           => undef,
    );
  my $model  = RDF::Trine::Model->temporary_model;
  my $writer = RDF::Trine::Serializer->new('RDFXML');
  
  $parser->parse_into_model($base_uri, $markup, $model);
  print $writer->serialize_model_to_string($model);

=head1 DESCRIPTION

This module parses data embedded in HTML. It understands the following standards
and patterns for embedding data:

=over

=item * RDFa L<http://www.w3.org/TR/rdfa-syntax/>

=item * Microformats L<http://microformats.org/>

=item * GRDDL L<http://www.w3.org/TR/grddl/>

=item * Microdata L<http://www.w3.org/TR/microdata/>

=item * N3-in-HTML L<http://esw.w3.org/N3inHTML>

=back

This module is just a wrapper around L<RDF::RDFa::Parser>, L<HTML::Microformats>,
L<XML::GRDDL>, L<HTML::HTML5::Microdata::Parser> and L<HTML::Embedded::Turtle>.
It is a subclass of L<RDF::Trine::Parser> so inherits the same interface as that.

=head2 Constructor Options

The methods presented by an HTML::Data::Parser object are exactly the same as any
other common-or-garden L<RDF::Trine::Parser> object. The constructor options are
where it gets interesting.

The options accepted are:

=over

=item * B<dom_parser> - set to 'xml' or 'html5' to determine which parser to
use on input strings. Defaults to 'html5'.

=item * B<named_graphs> - boolean; whether to return quads to handler in
C<parse> method. For advanced use only.

=item * B<on_error> - what to do when an error occurs. (Currently
only a subset of all possible errors are covered by this option. Some errors
thrown by other modules won't be caught.) Set to 'warn', 'die', 'ignore'
or a callback coderef (which is passed one parameter - the error message
as a string). Defaults to 'warn'.

=item * B<options_microdata> - a hashref of options to pass through to
C<< HTML::HTML5::Microdata::Parser->new >> if/when parsing microdata.

=item * B<options_rdfa> - an L<RDF::RDFa::Parser::Config> object to use
if/when parsing RDFa.

=item * B<parse_grddl> - a "troolean" (yes/no/maybe-so). Set to true to indicate
that you want GRDDL to be parsed. Set to false to indicate that you want it to
be ignored. Set to undef if you don't really care: this will parse GRDDL if the
required module (XML::GRDDL) is installed and working, but won't complain if it's
not. Defaults to false.

=item * B<parse_microdata> - another troolean. Defaults to undef.

=item * B<parse_microformats> - another troolean. Defaults to undef.

=item * B<parse_n3> - another troolean. Defaults to undef.

=item * B<parse_rdfa> - another troolean. Defaults to 1.

=back

=head1 SEE ALSO

This module is just a wrapper around:
L<RDF::RDFa::Parser>,
L<HTML::Microformats>,
L<XML::GRDDL>,
L<HTML::HTML5::Microdata::Parser>,
L<HTML::Embedded::Turtle>.

And around these DOM parsers:
L<HTML::HTML5::Parser>,
L<XML::LibXML>.

It sits on top of Trine:
L<RDF::Trine>,
L<RDF::Trine::Parser>,
L<RDF::TrineShortcuts>.

For more information on processing web data in Perl:
L<http://www.perlrdf.org/>.

=head1 AUTHOR

Toby Inkster E<lt>tobyink@cpan.orgE<gt>.

=head1 COPYRIGHT

Copyright 2010 Toby Inkster

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut


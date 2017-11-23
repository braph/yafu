#!/usr/bin/env perl

eval 'exec /usr/bin/perl  -S $0 ${1+"$@"}'
    if 0; # not running under some shell

=begin COPYRIGHT

   yafu.pl - Upload Files to Yet-Another-File-Upload Services
   Copyright (C) 2015 Benjamin Abendroth
   
   This program is free software: you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.
   
   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.
   
   You should have received a copy of the GNU General Public License
   along with this program.  If not, see <http://www.gnu.org/licenses/>.

=end COPYRIGHT

=cut

use 5.010001;
use feature 'say';

use strict;
use warnings;
use autodie;

use Try::Tiny;
use Tie::File;
use Time::Piece;
use Time::Seconds;
use WWW::Mechanize;
use File::Basename qw(basename);
use URI::Escape qw(uri_escape);
use Config::General qw(ParseConfig);
use Getopt::Long qw(:config gnu_getopt auto_version);

use constant DB_FIELDS => qw(id delete_id base file date expire_date expires hidden);
use constant DB_DELIMITER => "\t";

use constant CONFIG_DIR => $ENV{HOME} . '/.config/yafu';
use constant DEFAULT_CONFIG => CONFIG_DIR . '/yafu.rc';

use constant SHORTCUTS => qw(
   b basename
   f file
   i info_url
   d delete_url
   u direct_url
   D date
   e expire_date
   x expired
   E expires
   h hidden
);

use constant DEFAULT_FORMAT => q(=== %basename% {expired?[EXPIRED] }===
File: %file%
Date: %date%
Expires: %expire_date% [%expires%]
Type: {hidden?Private:Public}
URL: %direct_url%
Info: %info_url%
Delete: %deletion_url%
);

$main::VERSION = "0.6";

# for --list and --delete
my %actions;

# we save our Formatter-Obj here
my $formatter;

# application settings (also available via config file)
my %options = (
   'base'          => 'http://pixelbanane.de/yafu',

   'db'            => CONFIG_DIR . '/yafu.db',

   'email'         => '',
   'password'      => '',
   'comment'       => '',
   'hidden'        => 1,
   'expires'       => '1w',

   'format'        => DEFAULT_FORMAT,
   'show-expired'  => 0,
   'number'        => 0
);

exit main();

sub main
{
   init();

   my @yafudb;
   my $exit = 0;

   if ($options{db} ne '') {
      tie @yafudb, 'Tie::File', $options{db}
         or die "Could not open yafudb: $!";
   }

   if ($actions{delete}) {
      die "Missing arguments for --delete\n" if ! @ARGV;

      for my $link (@ARGV) {
         try
         {
            delete_url($link, \@yafudb);
         }
         catch
         {
            $exit = 1;
            say STDERR "Error while deleting '$link': $_";
         };
      }
   }
   elsif (@ARGV) {
      for my $file (@ARGV) {
         try
         {
            upload($file, \@yafudb);
         }
         catch
         {
            $exit = 1;
            say STDERR "Error while uploading '$file': $_";
         };
      }
   }

   if (! @ARGV || $actions{list}) {
      try
      {
         list_urls(\@yafudb);
      }
      catch
      {
         $exit = 1;
         say STDERR "Error while listing: $_";
      };
   }

   untie @yafudb if ($options{db} ne ''); 
   return $exit;
}

exit main;

sub checkOptions
{
   die "Invalid value for 'expires'\n"
      if $options{expires} !~ /^(30m|1h|6h|1d|3d|1w|max)$/;
}

sub init
{
   # setup config dir
   -d CONFIG_DIR || mkdir CONFIG_DIR || die "Config dir not available: $!\n";

   # process "pseudo-options" and actions first
   Getopt::Long::Configure qw(pass_through);

   my $getopt_config;
   my $getopt_no_config;

   GetOptions(
      'help|h'          => \&print_help,
      'example-config'  => \&print_config,
      'config=s'        => \$getopt_config,
      'no-config'       => \$getopt_no_config,
      'list|l'          => \$actions{list},
      'delete|d'        => \$actions{delete}
   );

   # read the config file
   if (! $getopt_no_config)
   {
      # use --config (or DEFAULT_CONFIG *if* it exists)
      my $rcFile = $getopt_config || -e DEFAULT_CONFIG && DEFAULT_CONFIG;

      if ($rcFile)
      {
         my %rcHash = ParseConfig(
            -ConfigFile => $rcFile,
            -AllowMultiOptions => 'no',
            -InterPolateEnv => 'yes'
         );

         for (keys %rcHash) {
            die "Config file: Unknown option: $_\n" if ! exists $options{$_};
         }

         %options = (%options, %rcHash);

         try {
            checkOptions
         }
         catch {
            die "Config File: $_";
         };
      }
   }

   # now read (and overwrite) the "real options"
   Getopt::Long::Configure qw(no_pass_through);

   GetOptions(\%options,
      'base|b=s',

      'db=s',
      'no-db'           => sub { $options{db} = '' },

      'format|f=s',
      'show-expired|x',
      'number|n=i',

      'email|e=s',
      'password|p=s',
      'comment|c=s',
      'expires|E=s',
      'private'         => sub { $options{hidden} = 1 },
      'public'          => sub { $options{hidden} = 0 }
   ) or exit 1;

   try {
      checkOptions
   }
   catch {
      die "Command Line: $_";
   };
}

sub print_help
{
   require Pod::Usage;
   Pod::Usage::pod2usage(-exitstatus => 0, -verbose => 2);
}

sub print_config
{
   for (keys %options)
   {
      my $value = $options{$_};
      $value =~ s/\n/\\n/smg;

      say "$_ = $value";
   }

   exit 0;
}

sub writeRecord
{
   my ($record, $db) = @_;
   push @$db, join(DB_DELIMITER, @$record{(DB_FIELDS)});
}

sub readRecord
{
   my $line = shift;

   my @fields = split(DB_DELIMITER, $line);

   return map { (DB_FIELDS)[$_] => $fields[$_] } (0..$#fields);
}

sub printRecord
{
   my ($record, $format) = @_;

   $formatter = Formatter->new($format) if ! $formatter;

   my $formatted = $formatter->fill(
         sub { getRecordVar($record, $_[0]) },
         sub { getRecordVar($record, $_[0]) }
   );

   say $formatted if $formatted;
}

sub getRecordVar
{
   my ($rec, $var) = @_;

   if ($var =~ /^\w$/) {
      die "Shortcut $var not found for record\n" if ! {SHORTCUTS}->{$var};
      $var = {SHORTCUTS}->{$var};
   }

   return $rec->{$var} if exists $rec->{$var};

   return $rec->{expired} =
      ($rec->{expires} ne 'max' &&
       $rec->{expire_date} lt localtime->strftime('%Y-%m-%d %H:%M:%S'))
      if $var eq 'expired';

   return $rec->{basename} = basename($rec->{file})
      if $var eq 'basename';

   return $rec->{basename_e} = uri_escape(getRecordVar($rec, 'basename'))
      if $var eq 'basename_e';

   return qq($rec->{base}/$rec->{id}/) . getRecordVar($rec, 'basename_e')
      if $var eq 'direct_url';

   return qq($rec->{base}/info/$rec->{id}/) . getRecordVar($rec, 'basename_e')
      if $var eq 'info_url';

   return qq($rec->{base}/delete/$rec->{delete_id})
      if $var eq 'deletion_url';

   die "Key $var not found in record\n";
}

sub upload
{
   my ($file, $db) = @_;

   my %params = %options{'email', 'expires', 'password', 'comment'};
   $params{upload} = $file;
   $params{filename} = basename($file);
   $params{hidden} = 'true' if $options{hidden};

   my $mech = WWW::Mechanize->new;
   $mech->get($options{base} . '/index.php');
   $mech->submit_form(
         form_id  => 'UploadForm',
         fields => \%params
   );

   my %record = %options{'base', 'hidden', 'expires'};
   $record{file} = $file;

   unless ( ($record{id}) =
         $mech->content =~ m!href="[^"]*/info/([0-9]+)/[^"]+!)
   {
      $record{id} = 'n/a';
   }

   unless ( ($record{delete_id}) =
         $mech->content =~ m!http://.+/delete/([^"]+)!)
   {
      $record{delete_id} = 'n/a';
   }

   if ($record{id} eq 'n/a' || $record{delete_id} eq 'n/a')
   {
      say STDERR 'Could not extract all information';

      try      
      {
         require File::Temp;

         my ($temp_fh, $temp_name) = File::Temp::tempfile();
         print $temp_fh $mech->content; 
         say STDERR "Dumped response to '$temp_name'";
         close $temp_fh;
      }
      catch
      {
         say STDERR "Could not dump respone: $_";
      };
   }

   my $now = localtime;
   $record{date} = $now->strftime('%Y-%m-%d %H:%M:%S');

   if (my ($repeat, $type) = $record{expires} =~ /([0-9]+)([a-z])/)
   {
      $record{expire_date} =
      (
         $now + $repeat *
         {
            m => ONE_MINUTE,
            h => ONE_HOUR,
            d => ONE_DAY,
            w => ONE_WEEK

         }->{$type}

      )->strftime('%Y-%m-%d %H:%M:%S');
   }
   else
   {
      $record{expire_date} = 0;
   }

   writeRecord(\%record, $db);
   printRecord(\%record, $options{format});
}

sub delete_url
{
   my ($url, $db) = @_;

   my $mech = WWW::Mechanize->new;
   $mech->get($url);
   $mech->submit_form( button => 'confirm');
}

sub list_urls
{
   my $db = shift;

   my $start = 0;

   if ($options{number} && $options{number} < scalar @$db)
   {
      $start = scalar @$db - $options{number};
   }

   for my $i ($start..$#{ $db })
   {
      my %record = readRecord($db->[$i]);

      next if (! $options{'show-expired'} && getRecordVar(\%record, 'expired'));

      printRecord(\%record, $options{format});
   }
}

package Formatter::List
{
   sub new
   {
      return bless [], shift;
   }

   sub add
   {
      my ($self, $child) = @_;

      # if $child is charater and prev. element is string
      if ( !ref($child) && @$self && !ref($self->[-1]) )
      {
         # append $child to string
         $self->[-1] .= $child;
      }
      else
      {
         push @$self, $child;
      }
   }

   sub fill
   {
      my ($self, $condCallback, $valueCallback) = @_;

      my $result = '';

      for (@$self)
      {
         if (! ref $_) {
            $result .= $_;
         }
         else {
            $result .= $_->fill($condCallback, $valueCallback);
         }
      }

      return $result;
   }
}

package Formatter::Variable
{
   sub new
   {
      my ($class, $var) = @_;
      return bless \$var, $class;
   }

   sub fill
   {
      my ($self, $condCallback, $valueCallback) = @_;
      return $valueCallback->($$self);
   }
}

package Formatter::Conditional
{
   sub new
   {
      my ($class, $var) = @_;

      return bless {
         variable => $var,
         state => 'true',
         true => Formatter::List->new,
         false => Formatter::List->new
      }, $class;
   }

   sub add
   {
      my ($self, $child) = @_;

      $self->{ $self->{state} }->add($child);
   }

   sub flip
   {
      $_[0]->{state} = 'false';
   }

   sub fill
   {
      my ($self, $condCallback, $valueCallback) = @_;

      if ( $condCallback->( $self->{variable} ) ) {
         return $self->{true}->fill($condCallback, $valueCallback);
      }
      else {
         return $self->{false}->fill($condCallback, $valueCallback);
      }
   }
}

package Formatter
{
   sub new
   {
      my ($class, $format) = @_;

      open(my $fmt_handle, '<', \$format);
      local *STDIN = *$fmt_handle;

      return Formatter::parse( Formatter::List->new );
   }

   sub parse
   {
      my $obj = shift;

      while (my $c = getc)
      {
         if ($c eq '%')
         {
            my $var = '';
            $var .= $c while ( ($c = getc) && $c ne '%' );

            die "Missing variable name after '%'" unless $var;
            die "Trailing '%' not found" unless $c;

            $obj->add(Formatter::Variable->new($var));
         }
         elsif ($c eq '{')
         {
            my $var = '';
            $var .= $c while ( ($c = getc) && $c ne '?' );

            die "Missing variable name after '{'" unless $var;
            die "Missing '?' inside '{...}'" unless $c;

            my $n_obj = Formatter::Conditional->new($var);

            Formatter::parse($n_obj);

            $obj->add($n_obj);
         }
         elsif ($c eq '}')
         {
            die "Closing '}' without beginning '{'" if ! $obj->isa('Formatter::Conditional');
            return $obj;
         }
         elsif ($c eq ':' && $obj->isa('Formatter::Conditional') && $obj->{state} eq 'true')
         {
            $obj->flip;
         }
         else
         {
            if ($c eq '\\')
            {
               $c = getc || die "Missing character after '\\'";

               next if ($c eq "\n");

               $c = {
                  n => "\n",
                  t => "\t" 
               }->{$c} || $c;
            }

            $obj->add($c);
         }
      }

      die "Missing closing '}'" if $obj->isa("Formatter::Conditional");
      return $obj;
   }
}

__END__

=pod 

=head1 NAME

yafu.pl - Upload Files to Yet-Another-File-Upload Services

=head1 SYNOPSIS

=over

yafu.pl [I<OPTION>]... [ARGS]...

=back

=head1 OPTIONS

=head2 Basic Startup Options

=over

=item B<--help>

Display this help text and exit.

=item B<--version>

Display the script version and exit.

=item B<--example-config>

Display an example configuration file and exit.

=back

=head2 Actions

=over

=item B<--delete|-d>

Delete the URLs given on the rest of the command line.

=item B<--list|-l>

List all files including information.

=back

=head2 General Options

=over

=item B<--config> I<file>

Use config file given in I<file>.

=item B<--no-config>

Don't use a configuration file at all.

=item B<--db> I<file>

Use I<file> as database file.

=item B<--no-db>

Don't use a database file at all.

=back

=head2 List Options

=over

=item B<--show-expired>

Also list expired files.

=item B<--number|-n> I<NUM>

Only print out the last I<NUM> records.

=item B<--format|-f> I<format>

Specify output format.

Variables are enclosed inside I<%...%>.

Conditional expressions: B<{>I<VARIABLE>B<?>I<print if true>B<:>I<print if result>B<}>.

Escaping I<char>s like "B<{>", "B<%>" and "B<:>" via B<\>I<char>.

Available variables are:
B<file|f>, B<basename|b>,
B<direct_url|u>, B<deletion_url|d>, B<info_url|i>
B<date|D>, B<expire_date|e>, B<expires|E>,
B<id>, B<delete_id>

Boolean variables:
B<expired|x>, B<hidden|h> 

B<Example>:

"URL: %I<direct_url>% {I<expired>?EXPIRED:%I<deletion_url>%}"

Will print the I<direct_url>. It will also print the I<deletion_url> if I<expired> is B<false>, else it will print "EXPIRED".

=back

=head2 Upload Options

=over

=item B<--base> I<URL>

Use I<URL> as base url for yafu. Defaults to I<http://pixelbanane.de/yafu>.

=item B<--email> I<email>

Use I<email> for email field.

=item B<--password> I<password>

Use I<password> as password.

=item B<--comment> I<comment>

Use I<comment> as comment.

=item B<--private>

Don't put the file in the public file list. This is the default.

=item B<--public>

Put the file in the public file list.

=item B<--expires> I<time>

Set when the file will expire on the server. I<time> can be:

B<30m>: 30 minutes,
B<1h>: 1 hour, B<6h>: 6 hours,
B<1d>: 1 day, B<3d>: 3 days,
B<1w>: 1 week,
B<max>: Till the very end

Defaults to I<1w>.

=back   

=head1 CONFIGURATION

=over

See B<--example-config>.

Environment variables like B<$HOME> can be used insied the configuration file.

Example:

B<expires> = "I<1d>"

B<comment> = "I<my standard comment>"

B<hidden> = I<0>

B<db> = I<$HOME/yafu.db>

=back

=head1 FILES

=over

=item I<$HOME/.config/yafu/yafu.rc>

Default configuration file. See B<--config>.

=item I<$HOME/.config/yafu/yafu.db>

Default database file. See B<--db>.

=back

=head1 AUTHOR

Written by Benjamin Abendroth.

=cut


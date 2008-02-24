# Copyright 2008 Raphaël Hertzog <hertzog@debian.org>

# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package Dpkg::Source::Package;

use strict;
use warnings;

use Dpkg::Gettext;
use Dpkg::ErrorHandling qw(error syserr warning internerr);
use Dpkg::Fields;
use Dpkg::Cdata;
use Dpkg::Checksums;
use Dpkg::Version qw(parseversion);
use Dpkg::Deps qw(@src_dep_fields);

use File::Basename;

my @dsc_fields = (qw(Format Source Binary Architecture Version Origin
		     Maintainer Uploaders Dm-Upload-Allowed Homepage
		     Standards-Version Vcs-Browser Vcs-Arch Vcs-Bzr
		     Vcs-Cvs Vcs-Darcs Vcs-Git Vcs-Hg Vcs-Mtn Vcs-Svn),
                  @src_dep_fields,
                  qw(Files));

# Object methods
sub new {
    my ($this, %args) = @_;
    my $class = ref($this) || $this;
    my $self = {
        'fields' => Dpkg::Fields::Object->new(),
        'options' => {},
    };
    bless $self, $class;
    if (exists $args{"filename"}) {
        $self->initialize($args{"filename"});
    }
    if (exists $args{"options"}) {
        $self->{'options'} = $args{'options'};
    }
    return $self;
}

sub initialize {
    my ($self, $filename) = @_;
    my ($fn, $dir) = fileparse($filename);
    error(_g("%s is not the name of a file"), $filename) unless $fn;
    $self->{'basedir'} = $dir || "./";
    $self->{'filename'} = $fn;

    # Check if it contains a signature
    open(DSC, "<", $filename) || syserr(_g("cannot open %s"), $filename);
    $self->{'is_signed'} = 0;
    while (<DSC>) {
        next if /^\s*$/o;
        $self->{'is_signed'} = 1 if /^-----BEGIN PGP SIGNED MESSAGE-----$/o;
        last;
    }
    close(DSC);
    # Read the fields
    open(CDATA, "<", $filename) || syserr(_g("cannot open %s"), $filename);
    my $fields = parsecdata(\*CDATA,
            sprintf(_g("source control file %s"), $filename),
            allow_pgp => 1);
    close(CDATA);
    $self->{'fields'} = $fields;

    foreach my $f (qw(Source Format Version Files)) {
        unless (defined($fields->{$f})) {
            error(_g("missing critical source control field %s"), $f);
        }
    }

    $self->parse_files();

    $self->upgrade_object_type();
}

sub upgrade_object_type {
    my ($self) = @_;
    my $format = $self->{'fields'}{'Format'};

    if ($format =~ /^([\d\.]+)(?:\s+\((.*)\))?$/) {
        my ($version, $variant) = ($1, $2);
        $version =~ s/\./_/;
        my $module = "Dpkg::Source::Package::V$version";
        $module .= "::$variant" if defined $variant;
        eval "require $module";
        if ($@) {
            error(_g("source package format `%s' is not supported (perl module %s is required)"), $format, $module);
        }
        bless $self, $module;
    } else {
        error(_g("invalid Format field `%s'"), $format);
    }
}

sub get_filename {
    my ($self) = @_;
    return $self->{'basedir'} . $self->{'filename'};
}

sub get_files {
    my ($self) = @_;
    return keys %{$self->{'files'}};
}

sub parse_files {
    my ($self) = @_;
    my $rx_fname = qr/[0-9a-zA-Z][-+:.,=0-9a-zA-Z_~]+/;
    my $files = $self->{'fields'}{'Files'};
    foreach my $file (split(/\n /, $files)) {
        next if $file eq '';
        $file =~ m/^($check_regex{md5})                    # checksum
                    [ \t]+(\d+)                            # size
                    [ \t]+($rx_fname)                      # filename
                  $/x
          || error(_g("Files field contains bad line `%s'"), $file);
        if (exists $self->{'files'}{$3}) {
            error(_g("file `%s' listed twice in Files field"), $3);
        } else {
            $self->{'files'}{$3} = $2;
        }
    }
}

sub check_checksums {
    my ($self) = @_;
    my ($fields, %checksum, %size) = $self->{'fields'};
    my $has_md5 = 1;
    if (not exists $fields->{'Checksums-Md5'}) {
        $fields->{'Checksums-Md5'} = $fields->{'Files'};
        $has_md5 = 0;
    }
    # extract the checksums from the fields in two hashes
    readallchecksums($self->{'fields'}, \%checksum, \%size);
    delete $fields->{'Checksums-Md5'} unless $has_md5;
    # getchecksums verify the checksums if they are pre-filled
    foreach my $file ($self->get_files()) {
        getchecksums($self->{'basedir'} . $file, $checksum{$file},
                     \$size{$file});
    }
}

sub get_basename {
    my ($self, $with_revision) = @_;
    my $f = $self->{'fields'};
    unless (exists $f->{'Source'} and exists $f->{'Version'}) {
        error(_g("source and version are required to compute the source basename"));
    }
    my %v = parseversion($f->{'Version'});
    my $basename = $f->{'Source'} . "_" . $v{"version"};
    if ($with_revision and $f->{'Version'} =~ /-/) {
        $basename .= "-" . $v{'revision'};
    }
    return $basename;
}

sub is_signed {
    my $self = shift;
    return $self->{'is_signed'};
}

sub check_signature {
    my ($self) = @_;
    my $dsc = $self->get_filename();
    if (-x '/usr/bin/gpg') {
        my $gpg_command = 'gpg -q --verify ';
        if (-r '/usr/share/keyrings/debian-keyring.gpg') {
            $gpg_command = $gpg_command.'--keyring /usr/share/keyrings/debian-keyring.gpg ';
        }
        $gpg_command = $gpg_command.quotemeta($dsc).' 2>&1';

        #TODO: cleanup here
        my @gpg_output = `$gpg_command`;
        my $gpg_status = $? >> 8;
        if ($gpg_status) {
            print STDERR join("",@gpg_output);
            error(_g("failed to verify signature on %s"), $dsc)
                if ($gpg_status == 1);
        }
    } else {
        warning(_g("could not verify signature on %s since gpg isn't installed"),
                $dsc);
    }
}

sub extract {
    error("Dpkg::Source::Package doesn't know how to unpack a source package. Use one of the subclass.");
}

# Function used specifically during creation of a source package

sub build {
    error("Dpkg::Source::Package doesn't know how to build a source package. Use one of the subclass.");
}

sub add_file {
    my ($self, $filename) = @_;
    if (exists $self->{'files'}{$filename}) {
        internerr(_g("tried to add file `%s' twice"), $filename);
    }
    my (%sums, $size);
    getchecksums($filename, \%sums, \$size);
    $self->{'files'}{$filename} = $size;
    foreach my $alg (sort keys %sums) {
        $self->{'fields'}{"Checksums-$alg"} .= "\n $sums{$alg} $size $filename";
    }
    $self->{'fields'}{'Files'}.= "\n $sums{md5} $size $filename";
}

sub write_dsc {
    my ($self, %opts) = @_;
    my $fields = $self->{'fields'};

    foreach my $f (keys %{$opts{'override'}}) {
	$fields->{$f} = $opts{'override'}{$f};
    }

    unless($opts{'nocheck'}) {
        foreach my $f (qw(Source Version)) {
            unless (defined($fields->{$f})) {
                error(_g("missing information for critical output field %s"), $f);
            }
        }
        foreach my $f (qw(Maintainer Architecture Standards-Version)) {
            unless (defined($fields->{$f})) {
                warning(_g("missing information for output field %s"), $f);
            }
        }
    }

    foreach my $f (keys %{$opts{'remove'}}) {
	delete $fields->{$f};
    }

    my $filename = $opts{'filename'};
    unless (defined $filename) {
        $filename = $self->get_basename(1) . ".dsc";
    }
    open(DSC, ">", $filename) || syserr(_g("cannot write %s"), $filename);

    delete $fields->{'Checksums-Md5'}; # identical with Files field
    tied(%{$fields})->set_field_importance(@dsc_fields);
    tied(%{$fields})->output(\*DSC, $opts{'substvars'});
    close(DSC);
}

# vim: set et sw=4 ts=8
1;

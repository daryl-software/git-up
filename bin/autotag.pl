#!/usr/bin/perl 
#===============================================================================
#
#         FILE:  autotag.pl
#
#        USAGE:  ./autotag.pl  
#
#  DESCRIPTION:  auto-increment last tag
#
#      OPTIONS:  ---
# REQUIREMENTS:  ---
#         BUGS:  ---
#        NOTES:  ---
#       AUTHOR:  Grégory Duchatelet <skygreg@gmail.com>
#      COMPANY:  
#      VERSION:  1.0
#      CREATED:  06/20/2013 04:52:55 PM
#     REVISION:  ---
#===============================================================================

use strict;
use warnings;

use POSIX;
use feature qw/say/;
use Data::Dumper;
use Getopt::Long;
#use diagnostics;


#my @v = qw/v1 v1.2 v1.0.12 v12.0.3 v1-alpha v14.6.8-beta1 14.1.0 1.000 12.2 qsd12.2qsd v13-alpha1 14.5.8.1/;

sub find_last_version($$$)
{
	my $versions = shift;
	my $release = shift;
	my $version = shift;
	my %vers;
	my %tree;
	my $maxnumbers = 0;
	# compute version numbers
	foreach my $v (@$versions)
	{
		chomp $v;
		# tree
		#my $t = $tree;
		#$t = $t->{$_} //= {} for grep /\d/ => @parts;
		#
		# TODO: stocker les entiers en entier
		my @parts = split(/(\d+)/, $v);
		my $maxnumber = scalar(grep(/\d+/, @parts));
		$maxnumbers = $maxnumber if $maxnumber gt $maxnumbers;
		$vers{$v} = {'parts' => \@parts, 'numbers' => $maxnumber};
	}

	# complete missing version tabs with '0'
	foreach my $v (@$versions)
	{
		for (my $i=$vers{$v}{'numbers'}; $i < $maxnumbers; $i++)
		{
			push @{$vers{$v}{'parts'}}, 0;
		}
	}

	# sort!
	my @lastvers;
	for my $i ( 0 .. $maxnumbers-1 )
	{
		my @keys;
		my @vals;

		foreach my $v (@$versions)
		{
			push @keys, $v;
			my @elems = grep /\d/, @{$vers{$v}{'parts'}};
			# filter
			if (defined($lastvers[$i-1]))
			{
				if ($elems[$i-1] == $lastvers[$i-1])
				{
					if ($i > 1 && defined($lastvers[$i-2]))
					{
						if ($elems[$i-2] == $lastvers[$i-2])
						{
							push @vals, int($elems[$i]);
						}
					}
					else
					{
						push @vals, int($elems[$i]);
					}
				}
			}
			else
			{
				push @vals, int($elems[0]);
			}
		}
		
		# find max
		my $max = (sort { $b <=> $a } @vals)[0]; # sort descending

		push @lastvers, $max;
	}

	if (defined($version))
	{
		return increment_version(\%vers, $release, $version) if (defined($vers{$version}));
		return undef;
	}

	# search matching version
	foreach my $v (@$versions)
	{
		my @elems = grep /\d/, @{$vers{$v}{'parts'}};
		for my $i (0 .. $#lastvers)
		{
			if ($elems[$i] != $lastvers[$i])
			{
				last;
			}
			# found!
			if ($i == $#lastvers)
			{
				return increment_version(\%vers, $release, $v);
			}
		}
	}
	return undef;
}


sub increment_version($$$)
{
	my $vers = shift;
	my $release = shift;
	my $v = shift;
	for (my $j=scalar(@{$vers->{$v}{'parts'}})-1; $j>=0; $j--)
	{
		if ($vers->{$v}{'parts'}[$j] =~ /\d/)
		{
			# En mode release, le dernier numéro passe à 0
			# et on refait une passe pour incrémenter le numéro suivant
			# en spécifiant plusieurs --release, on incremente de plus en plus haut
			if ($release)
			{
				$release--;
				$vers->{$v}{'parts'}[$j] = 0;
				next;
			}
			$vers->{$v}{'parts'}[$j]++;
			last;
		}
	}
	return join('', @{$vers->{$v}{'parts'}});
}


# 
# MAIN
#

my $short = 1;
my $version;
my $release = 0;
my $nofetch = 0;
GetOptions(
	"short!" => \$short,
	"version=s" => \$version,
	"release+" => \$release,
	"nofetch" => \$nofetch,
);

if ($nofetch or (system('git fetch --verbose origin') == 0))
{
	my @tags;
	if (!isatty(*STDIN))
	{
		while (<STDIN>)
		{
			chomp;
			push @tags, $_;
		}
	}
	else
	{
		@tags = `git tag -l`;
	}
	@tags = grep /^v/, @tags;

	my $newtag = find_last_version(\@tags, $release, $version);
	if (defined($newtag))
	{
		if ($short)
		{
			say $newtag;
		}
		else
		{
			say "============================================";
			say "New tag: $newtag | next steps:";
			say "============================================";
			say "git tag $newtag && git push origin $newtag";
			say "============================================";
		}
	}
}
else
{
	warn "git fetch FAILED.$/";
}



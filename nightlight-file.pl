#!/usr/bin/perl
# Descriptor-held file access for the Night Light widget.
#
# Every operation opens the config's parent directory with O_DIRECTORY and
# O_NOFOLLOW, verifies that descriptor with fstat, and fchdirs into it; it
# then works relative to the held directory with O_NOFOLLOW and O_EXCL, and
# validates each opened file via fstat on its descriptor. A
# pathname swapped in after the check therefore cannot redirect a read or
# write, and non-regular files are never read.
#
#   read   <conf> <marker>   print "__PENDING__\n" if marker exists, then up to 64 KiB of conf
#   write  <conf> <body>     atomically replace conf with body
#   mark   <marker>          create marker
#   unmark <marker>          remove marker
#
# Exit codes: 0 ok, 1 error, 3 path is a symlink or not a regular file.
use strict;
use warnings;
use Fcntl qw(O_RDONLY O_WRONLY O_CREAT O_EXCL O_NOFOLLOW O_NONBLOCK O_DIRECTORY :mode);
use File::Basename qw(dirname basename);

my ($mode, $path, $extra) = @ARGV;
defined $mode && defined $path or exit 1;

# Open the parent directory itself (no symlink following), verify the opened
# descriptor is a directory, and fchdir into it. Everything afterwards is
# relative to that held descriptor, so replacing the pathname cannot redirect it.
sub enter_dir {
  my ($p) = @_;
  my $dir = dirname($p);
  sysopen(my $dh, $dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or return 0;
  my @st = stat($dh);
  (@st && S_ISDIR($st[2])) or return 0;
  chdir($dh) or return 0;
  return basename($p);
}

sub write_atomic {
  my ($name, $body) = @_;
  my @ls = lstat($name);
  if (@ls && !S_ISREG($ls[2])) { return 3 }
  my $tmp = ".$name.$$.tmp";
  sysopen(my $fh, $tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0644) or return 1;
  my @fs = stat($fh);
  unless (@fs && S_ISREG($fs[2]) && print($fh $body) && close($fh)) { unlink $tmp; return 1 }
  unless (rename($tmp, $name)) { unlink $tmp; return 1 }
  return 0;
}

if ($mode eq 'read') {
  if (defined $extra) {
    my @m = lstat($extra);
    print "__PENDING__\n" if @m;
  }
  my $name = enter_dir($path) or exit 3;
  my $fh;
  unless (sysopen($fh, $name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)) { exit(-l $name ? 3 : 0) }
  my @fs = stat($fh);
  (@fs && S_ISREG($fs[2])) or exit 3;
  my $buf = '';
  sysread($fh, $buf, 65536);
  print $buf;
  exit 0;
}
elsif ($mode eq 'write') {
  defined $extra or exit 1;
  my $name = enter_dir($path) or exit 3;
  exit write_atomic($name, $extra);
}
elsif ($mode eq 'mark') {
  my $name = enter_dir($path) or exit 1;
  sysopen(my $fh, $name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0644);
  exit 0;
}
elsif ($mode eq 'unmark') {
  my $name = enter_dir($path) or exit 0;
  unlink $name;
  exit 0;
}
exit 1;

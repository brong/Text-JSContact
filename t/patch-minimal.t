#!/usr/bin/perl

# patch_vcard must change only what the Card change asks for: a vCard from
# Apple or Google carries grouped lines, labels, X- properties and vendor
# parameters that JSContact cannot represent, and a client that saves one
# edited email must not lose or rewrite them.  Known failures are TODO with
# the lib line responsible.

use strict;
use warnings;
use Test::More;
use Storable qw(dclone);
use JSON;
use Encode ();
use Text::VCardFast qw(vcard2hash);

use lib 'lib';
use Text::JSContact qw(vcard_to_jscontact jscontact_to_vcard patch_vcard);

my $DIR = 't/data/vcard';

sub slurp {
  my ($file) = @_;
  open my $fh, '<:raw', "$DIR/$file" or die "$file: $!";
  local $/;
  return scalar <$fh>;
}

# content lines, unfolded, without line endings
sub lines {
  my ($v) = @_;
  $v =~ s/\r?\n[ \t]//g;
  return grep { length } split /\r?\n/, $v;
}

# a property as Text::VCardFast parses it, comparable regardless of the case
# of names and of parameter order
my $CANON = JSON->new->canonical;
sub props {
  my ($v) = @_;
  my $p = vcard2hash($v, multival => [qw(n adr org)])->{objects}[0]{properties};
  my @out;
  for my $name (sort keys %$p) {
    for my $item (@{$p->{$name}}) {
      push @out, {
        name   => $name,
        group  => lc($item->{group} // ''),
        params => $item->{params} // {},
        value  => $item->{values} // $item->{value},
        key    => $CANON->encode([$name, lc($item->{group} // ''), $item->{params} // {}, $item->{values} // $item->{value}]),
      };
    }
  }
  return @out;
}

sub find_id {
  my ($map, $field, $value) = @_;
  my ($id) = grep { ($map->{$_}{$field} // '') eq $value } keys %$map;
  return $id;
}

my $REWRITE = 'patch_vcard re-serialises the whole vCard (_hash2vcard, lib:1652): properties reordered, group and parameter names upper-cased, lines refolded';
my $V4IN3   = 'patch_vcard splices the vCard 4 writer output (PROP-ID lib:1157, PREF lib:1056, lower-case TYPE) into a 3.0 card (lib:1647-1652)';
my $LABEL   = 'X-ABLabel only written for emails and phones (_add_label: lib:1161,1190); patching a property drops the labels of its other values';

# a map of objects as a sorted list, to compare without the ids
sub by_value {
  my ($v) = @_;
  return $v unless ref $v eq 'HASH' && !grep { ref $_ ne 'HASH' } values %$v;
  return [ sort map { $CANON->encode($_) } values %$v ];
}

# --- No change: the original, byte for byte ------------------------------

for my $file (sort map { s{^\Q$DIR\E/}{}r } glob "$DIR/*.vcf") {
  my $raw  = slurp($file);
  my $card = vcard_to_jscontact($raw);
  is(patch_vcard($raw, $card, dclone($card)), $raw, "$file: no change returns the original bytes");
  # as a JMAP client sends it back: through JSON
  my $json = JSON->new->utf8->canonical;
  my $back = $json->decode($json->encode($card));
  is(patch_vcard($raw, $card, $back), $raw, "$file: no change after a JSON round trip returns the original bytes");
}

# --- Apple vCard 3.0: change one email ---------------------------------

{
  my $raw  = slurp('apple-ios-person.vcf');
  my $old  = vcard_to_jscontact($raw);
  my $new  = dclone($old);
  my $id   = find_id($new->{emails}, address => 'j.appleseed@orchard.example');
  ok($id, 'Apple: found the work email');
  $new->{emails}{$id}{address} = 'johnny@orchard.example';

  my $patched = patch_vcard($raw, $old, $new);
  like($patched, qr/johnny\@orchard\.example/, 'Apple: new address written');
  unlike($patched, qr/j\.appleseed\@orchard\.example/, 'Apple: old address gone');

  # the email lines and their labels are the only ones allowed to change
  my %email_groups = map { lc($_->{group}) => 1 } grep { $_->{name} eq 'email' && $_->{group} } props($raw);
  my $is_email = sub {
    my $l = shift;
    return 1 if $l =~ /^(?:[\w-]+\.)?EMAIL[;:]/i;
    return 1 if $l =~ /^([\w-]+)\.X-ABLABEL[;:]/i && $email_groups{lc $1};
    return 0;
  };

  {
    local $TODO = $REWRITE;
    is_deeply([grep { !$is_email->($_) } lines($patched)],
              [grep { !$is_email->($_) } lines($raw)],
              'Apple: every other line is byte-identical and in the same order');
  }

  # semantically: every other property, with its group, params and value
  my %after = map { $_->{key} => 1 } props($patched);
  my @missing = map { "$_->{group}.$_->{name}" }
                grep { !$after{$_->{key}} }
                grep { $_->{name} ne 'email' && !($_->{name} eq 'x-ablabel' && $email_groups{$_->{group}}) }
                props($raw);
  is_deeply(\@missing, [], 'Apple: every other property kept, with its group, parameters and value');

  my $reread = vcard_to_jscontact($patched);
  my %by = map { $_->{address} => $_ } values %{$reread->{emails}};
  is($by{'jq@icloud.example'}{label}, 'iCloud', 'Apple: the label of an untouched email survives');
  is_deeply([sort keys %by], [sort map { $_->{address} } values %{$new->{emails}}], 'Apple: the emails are the new ones');
  my @others = sort grep { $_ ne 'emails' } keys %$new;
  for my $key (@others) {
    is_deeply(by_value($reread->{$key}), by_value($new->{$key}), "Apple: $key unchanged after patching an email (ignoring ids)");
  }
  {
    is_deeply({ map { ($_ => $reread->{$_}) } @others }, { map { ($_ => $new->{$_}) } @others },
              'Apple: every other property unchanged, ids included');
  }

  like($patched, qr/^VERSION:3\.0\r?$/m, 'Apple: still VERSION:3.0');
  {
    local $TODO = $V4IN3;
    my @v4 = grep { /;(?:PROP-ID|PREF)=/i } lines($patched);
    is_deeply(\@v4, [], 'Apple: no vCard 4 parameters (PROP-ID, PREF) in a 3.0 card');
    my ($work) = grep { /johnny\@orchard/ } lines($patched);
    like($work // '', qr/^item2\.EMAIL;type=INTERNET;type=WORK:/,
         'Apple: the changed email keeps its group and its 3.0 parameters');
  }
}

# --- A new label must not take a group the original uses ----------------

{
  my $raw = slurp('google-export.vcf');
  my $old = vcard_to_jscontact($raw);
  my $new = dclone($old);
  my $id  = find_id($new->{emails}, address => 'alice@corp.example');
  $new->{emails}{$id}{label} = 'Office';
  my $reread = vcard_to_jscontact(patch_vcard($raw, $old, $new));
  is(($reread->{emails}{$id} // {})->{label}, 'Office', 'Google: new email label written');
  my $ph = find_id($reread->{phones}, number => '+1 650-555-0100');
  is(($reread->{phones}{$ph // ''} // {})->{label}, "Grandma's house",
     'Google: item1 phone keeps its own label');
}

# --- Ids: the untouched properties keep theirs --------------------------

{
  my $raw = slurp('google-export.vcf');
  my $old = vcard_to_jscontact($raw);
  my $new = dclone($old);
  my $id  = find_id($new->{emails}, address => 'alice@corp.example');
  $new->{emails}{$id}{address} = 'alice@newcorp.example';
  my $reread = vcard_to_jscontact(patch_vcard($raw, $old, $new));
  is_deeply([sort keys %{$reread->{emails}}], [sort keys %{$new->{emails}}], 'ids: patched emails keep their ids (written as PROP-ID)');
  is_deeply([sort keys %{$reread->{phones}}], [sort keys %{$old->{phones}}], 'ids: untouched phones keep their ids');
}

# --- Patching a property keeps what JSContact cannot say about it ---------

{
  my $raw = slurp('apple-ios-person.vcf');
  my $old = vcard_to_jscontact($raw);

  {
    my $new = dclone($old);
    $new->{name}{full} = 'Johnny Q. Appleseed';
    my $reread = vcard_to_jscontact(patch_vcard($raw, $old, $new));
    is($reread->{name}{full}, 'Johnny Q. Appleseed', 'Apple name: FN changed');
    local $TODO = 'patching name deletes X-PHONETIC-* (lib:1540) and _unconvert_name does not write them (lib:1088-1136)';
    is_deeply($reread->{name}{phoneticComponents}, $old->{name}{phoneticComponents}, 'Apple name: phonetic names kept');
  }

  {
    my $new = dclone($old);
    my $id  = find_id($new->{links}, uri => 'https://orchard.example/team/johnny');
    $new->{links}{$id}{uri} = 'https://orchard.example/people/johnny';
    my $reread = vcard_to_jscontact(patch_vcard($raw, $old, $new));
    my $home = find_id($reread->{links}, uri => 'https://johnny.example/');
    local $TODO = $LABEL;
    is(($reread->{links}{$home // ''} // {})->{label}, 'HomePage', 'Apple links: untouched URL keeps its label');
  }

  {
    my $new = dclone($old);
    my $bday = find_id($new->{anniversaries}, kind => 'birth');
    $new->{anniversaries}{$bday}{date} = '0000-07-05';
    my $patched = patch_vcard($raw, $old, $new);
    local $TODO = 'anniversaries are rewritten from the Card: the custom X-ABDATE (kind "started at orchard") becomes ANNIVERSARY (lib:1286) and its X-ABLabel is dropped';
    like($patched, qr/^item\d+\.X-ABDATE[;:].*2019-02-01/mi, 'Apple anniversaries: custom X-ABDATE kept');
  }
}

# --- Cyrus vCard 4.0: unknown properties and vendor parameters ------------

{
  my $raw = slurp('cyrus-carddav-v4.vcf');
  my $old = vcard_to_jscontact($raw);
  my $new = dclone($old);
  $new->{emails}{e1}{address} = 'jane@new-work.example';
  my $patched = patch_vcard($raw, $old, $new);
  my @after = lines($patched);
  ok((grep { /^X-CYRUS-SPECIAL;X-VENDOR-PARAM=keep:opaque value$/i } @after), 'Cyrus: X- property with vendor parameter kept');
  ok((grep { /^JSPROP;JSPTR="example\.com:foo":"bar"$/i } @after), 'Cyrus: JSPROP kept');
  ok((grep { /^GENDER:F$/ } @after), 'Cyrus: GENDER kept');
  ok((grep { /^EMAIL;.*PROP-ID=e1.*:jane\@new-work\.example$/ } @after), 'Cyrus: patched email keeps its PROP-ID');
  local $TODO = $REWRITE;
  is_deeply([grep { !/^EMAIL[;:]/ } @after], [grep { !/^EMAIL[;:]/ } lines($raw)],
            'Cyrus: every other line is byte-identical and in the same order');
}

# --- UTF-8: a patched vCard is still UTF-8 ---------------------------------

{
  my $raw = slurp('apple-company.vcf');
  my $old = vcard_to_jscontact($raw);
  for my $addr ("bestellung\@caf\x{e9}.example", "\x{6ce8}\x{6587}\@example.jp") {
    my $what = $addr =~ /[^\x00-\xff]/ ? 'a character above U+00FF' : 'a Latin-1 character';
    my $new = dclone($old);
    my ($id) = keys %{$new->{emails}};
    $new->{emails}{$id}{address} = $addr;
    my $patched = patch_vcard($raw, $old, $new);
    local $TODO = 'patch_vcard splices character strings from the Card into the byte strings Text::VCardFast parsed (lib:1647-1652): a value below U+0100 comes out as a Latin-1 byte, one above upgrades the string and the original UTF-8 is then double-encoded';
    my $bytes = utf8::is_utf8($patched) ? undef : $patched;
    ok(defined $bytes && eval { Encode::decode('UTF-8', my $copy = $bytes, Encode::FB_CROAK); 1 },
       "UTF-8: patching in $what gives a vCard of UTF-8 bytes");
    local $TODO = undef if $addr !~ /[^\x00-\xff]/;
    like(Encode::decode('UTF-8', $bytes // ''), qr/^FN:Caf\x{e9} M\x{fc}ller GmbH\r?$/m, "UTF-8: after patching in $what, the untouched FN still reads as UTF-8");
  }
}

# --- Apple group: members stay in Apple's form ----------------------------

{
  my $raw = slurp('apple-group.vcf');
  my $old = vcard_to_jscontact($raw);
  my $new = dclone($old);
  $new->{members}{'urn:uuid:11111111-2222-4333-8444-555555555555'} = JSON::true;
  my $patched = patch_vcard($raw, $old, $new);
  like($patched, qr/^X-ADDRESSBOOKSERVER-MEMBER:urn:uuid:11111111-2222-4333-8444-555555555555\r?$/m,
       'Apple group: new member as X-ADDRESSBOOKSERVER-MEMBER');
  unlike($patched, qr/^MEMBER:/m, 'Apple group: no vCard 4 MEMBER');
  like($patched, qr/^X-ADDRESSBOOKSERVER-KIND:group\r?$/m, 'Apple group: kind untouched');
  is(scalar keys %{vcard_to_jscontact($patched)->{members}}, 4, 'Apple group: four members');
}

done_testing;

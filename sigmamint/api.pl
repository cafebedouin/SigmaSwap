#!/usr/bin/perl
# SigmaMint - mint Ergo tokens and NFTs (EIP-4) from the Ergo wallet or a browser.
# Lives in a subdirectory of SigmaSwap and shares its config file, Python helper
# and virtualenv:   https://<host>/cgi-bin/sigmaswap/sigmamint/
#
#   Mosaik (inside the Ergo wallet)
#     GET  api.pl                          -> start screen: wallet address, then "Mint a token" / "Mint an NFT"
#     POST api.pl?action=form&k=token|nft  -> the form
#     POST api.pl?action=preview&k=...     -> check the input, show what will be minted + Mint button
#     POST api.pl?action=status&n=<id>     -> what happened to the mint
#   ErgoPay (EIP-20), fetched by the wallet at signing time
#     GET  api.pl?action=ergopay&n=<id>&addr=<address>
#   Browser page (index.html / app.js), POST FormData. Mosaik has no file picker,
#   so the NFT form's "Choose file" button opens this page with the wallet session's
#   id (?s=...). The file picked there is attached to that session; the user goes
#   back to the wallet and continues. Without a valid session id there is no upload.
#     action=config | upload
#
# Public, no login, no database. The server never signs anything. What it keeps:
# a short-lived note per mint (CACHE_DIR/tx/), and upload counters for rate limits.
# NFT media can be uploaded from the browser page; the file is checked and relayed
# to Lighthouse (IPFS/Filecoin) with the operator's API key and is NOT stored here.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use CGI ();
use JSON::PP ();
use Math::BigInt;
use File::Spec;
use Fcntl qw(:flock);
use Digest::SHA qw(sha256_hex hmac_sha256_hex);
use AppConfig qw(cfg base_url chain);
use MosaikKit;
use Unicode::Normalize qw(NFKC);

use constant APP_VERSION => 6;
use constant ERG         => '0' x 64;

my $MAX_MB = cfg('MINT_MAX_UPLOAD_MB', 10) + 0;
$MAX_MB = 10 unless $MAX_MB >= 1 && $MAX_MB <= 100;
# Large bodies and file uploads are accepted on the upload action only (named in the URL,
# so it is known before the body is read); everything else is a small JSON post.
my $IS_UPLOAD = (($ENV{QUERY_STRING} // '') =~ /(?:^|&)action=upload(?:&|\z)/) ? 1 : 0;
$CGI::POST_MAX        = $IS_UPLOAD ? ($MAX_MB + 1) * 1024 * 1024 : 64 * 1024;
$CGI::DISABLE_UPLOADS = $IS_UPLOAD ? 0 : 1;
# CGI.pm spools an upload to a temp file: keep that in our own writable directory
if (my $cd = cache_dir()) {
    my $tmp = File::Spec->catdir($cd, 'tmp');
    mkdir $tmp, 0770 unless -d $tmp;
    $ENV{TMPDIR} = $tmp if -d $tmp && -w $tmp;
}

my $cgi = CGI->new;
print $cgi->header(-type => 'application/json', -charset => 'utf-8', -cache_control => 'no-store');

my $BASE = base_url('sigmamint');
my $API  = "$BASE/api.pl";

my $action = $cgi->url_param('action');
$action = $cgi->param('action') unless defined $action && $action ne '';
$action = '' unless defined $action;
my $KIND = $cgi->url_param('k');
$KIND = 'token' unless defined $KIND && $KIND eq 'nft';

# The wallet session's id for attaching an NFT file. It is carried in the action
# URLs; a fresh one is issued whenever the wallet arrives without a valid one.
my $SESSION = $cgi->url_param('s');
$SESSION = new_session() unless session_ok($SESSION);

my %mosaik  = ('' => \&act_app, home => \&act_home, form => \&act_form, preview => \&act_preview, status => \&act_status);
my %plain   = (notify => \&act_notify);
my %browser = (config => \&web_config, upload => \&web_upload);

if ($cgi->cgi_error) {
    my $e = $cgi->cgi_error;
    die_json($e =~ /413/ ? "The file is too large (limit $MAX_MB MB)." : 'Bad request');
}
elsif ($action eq 'ergopay') {
    eval { act_ergopay(); 1 } or do { warn "sigmamint: ergopay failed: $@"; ergopay_error('Something went wrong. Please try again.') };
}
elsif (exists $mosaik{$action}) {
    eval { $mosaik{$action}->(); 1 } or do { warn "sigmamint: '$action' failed: $@"; mosaik_dialog('Something went wrong. Please try again.') };
}
elsif (exists $plain{$action}) {
    eval { $plain{$action}->(); 1 } or do { warn "sigmamint: '$action' failed: $@"; notify_json(undef, 0, 240) };
}
elsif (exists $browser{$action}) {
    eval { $browser{$action}->(); 1 } or do { warn "sigmamint: '$action' failed: $@"; die_json('Something went wrong') };
}
else {
    die_json('Unknown action');
}
exit;

# ================================================================ sessions ==
# A session id is issued only by the wallet screens and is signed with a secret
# that never leaves this server, so an upload cannot be started from anywhere
# else. Format: 16 hex time + 16 hex random + 32 hex signature. Valid for 2 hours.

sub server_secret {
    my $cd = cache_dir() or return undef;
    my $file = File::Spec->catfile($cd, 'mint-secret');
    if (!-s $file) {
        my $new = (new_nonce() // '') . (new_nonce() // '');
        return undef unless length($new) == 64;
        my $old = umask 0077;
        if (sysopen(my $fh, $file, Fcntl::O_WRONLY | Fcntl::O_CREAT | Fcntl::O_EXCL)) { print {$fh} $new; close $fh }
        umask $old;
    }
    open(my $fh, '<', $file) or return undef;
    my $secret = <$fh>;
    close $fh;
    return (defined $secret && $secret =~ /^([0-9a-f]{64})/) ? $1 : undef;
}

sub new_session {
    my $secret = server_secret() or return '';
    my $rand = new_nonce() or return '';
    my $body = sprintf('%016x', time) . substr($rand, 0, 16);
    return $body . substr(hmac_sha256_hex($body, $secret), 0, 32);
}

sub session_ok {
    my ($s) = @_;
    return 0 unless defined $s && $s =~ /^([0-9a-f]{32})([0-9a-f]{32})\z/;
    my ($body, $sig) = ($1, $2);
    my $secret = server_secret() or return 0;
    return 0 unless substr(hmac_sha256_hex($body, $secret), 0, 32) eq $sig;
    my $age = time - hex(substr($body, 0, 16));
    return ($age >= 0 && $age < 2 * 3600) ? 1 : 0;
}

sub session_key { return substr(sha256_hex("file|$_[0]"), 0, 32) }    # where a session's file note is stored

# =============================================================== validation ==

sub posted_values {
    my $raw = $cgi->param('POSTDATA');
    return {} unless defined $raw && length $raw;
    my $v = eval { JSON::PP->new->utf8->decode($raw) };
    return ref $v eq 'HASH' ? $v : {};
}

sub trim { my ($s) = @_; return '' unless defined $s && !ref $s; $s =~ s/^\s+|\s+\z//g; return $s }

# One normal form and no invisible characters, BEFORE any check: "Sig<zero-width space>USD"
# must be seen as the "SigUSD" it would be minted as.
sub clean_name {
    my ($s) = @_;
    $s = NFKC(trim($s));
    $s =~ s/[\p{Cf}\p{Cc}\p{Cs}\p{Co}\p{Cn}]//g;
    $s =~ s/\s+/ /g;
    return trim($s);
}

# Names that would pass for a well-known token: everything in the swap list.
sub reserved_names {
    my %r = map { $_ => 1 } qw(erg ergo sigusd sigrsv);
    my $cd = cache_dir();
    if ($cd && open(my $fh, '<', File::Spec->catfile($cd, 'pools.json'))) {
        local $/;
        my $d = eval { JSON::PP->new->utf8->decode(scalar <$fh>) };
        close $fh;
        if (ref $d eq 'HASH' && ref $d->{pools} eq 'ARRAY') {
            for my $p (@{ $d->{pools} }) { $r{ lc $_->{ticker} } = 1 for grep { ref $_ eq 'HASH' && defined $_->{ticker} } $p->{x}, $p->{y} }
        }
    }
    return \%r;
}

# Shared by the wallet form and the browser form. -> (\%draft) or (undef, "message")
sub check_draft {
    my ($kind, $in) = @_;
    my %d = (kind => $kind);
    $d{name}        = clean_name($in->{name});
    $d{description} = trim($in->{description});
    return (undef, 'Enter a name.')                              unless length $d{name};
    return (undef, 'The name is too long (40 characters at most).') if length($d{name}) > 40;
    return (undef, 'The description is too long (300 characters at most).') if length($d{description}) > 300;
    return (undef, 'That name belongs to a well-known token. Choose a different name.')
        if reserved_names()->{ lc $d{name} };

    if ($kind eq 'token') {
        my $whole = defined $in->{amount} && !ref $in->{amount} ? "$in->{amount}" : '';
        my $dec   = defined $in->{decimals} && !ref $in->{decimals} ? "$in->{decimals}" : '0';
        return (undef, 'Enter how many tokens to create (a whole number).') unless $whole =~ /^[1-9]\d{0,18}\z/;
        return (undef, 'Decimals must be between 0 and 9.')                 unless $dec =~ /^[0-9]\z/;
        my $raw = Math::BigInt->new($whole)->bmul(Math::BigInt->new(10)->bpow($dec));
        return (undef, 'That is more than a token can hold. Use a smaller amount or fewer decimals.')
            if $raw->bcmp(Math::BigInt->new('9223372036854775807')) > 0;
        @d{qw(amount decimals)} = ($raw->bstr, $dec + 0);
    }
    else {
        @d{qw(amount decimals)} = ('1', 0);
        for my $k (qw(cid sha256 media)) { $d{$k} = trim($in->{$k}) }
        $d{cid} =~ s{^ipfs://}{};
        return (undef, 'Add the picture, audio or video file first.')
            unless $d{cid} =~ /^(Qm[1-9A-HJ-NP-Za-km-z]{44}|b[a-z2-7]{50,100})\z/;
        return (undef, 'Add the picture, audio or video file first.')
            unless $d{sha256} =~ /^[0-9a-f]{64}\z/ && $d{media} =~ /^(picture|audio|video)\z/;
    }
    return (\%d);
}

sub describe {    # "1,000,000 MYTOKEN" / "the NFT “Name”"
    my ($d) = @_;
    return $d->{kind} eq 'nft' ? "the NFT \x{201C}$d->{name}\x{201D}"
                               : fmt_amount($d->{amount}, $d->{decimals}) . " $d->{name}";
}

sub ergopay_host { my $h = $BASE; $h =~ s{^https?://}{}; return $h }

sub new_draft {    # store what is to be minted under a random id; the wallet later asks for it by that id
    my ($d) = @_;
    my $nonce = new_nonce();
    return undef unless defined $nonce && record_file($nonce);
    save_record($nonce, { %$d, app => 'mint', t => time });
    return load_record($nonce) ? $nonce : undef;
}

# ============================================================ Mosaik views ==

sub text_field {
    my ($id, $label, $value, $max, %o) = @_;
    return child(O(type => 'TextInputField', id => $id, value => (defined $value && length $value ? $value : undef),
                   placeholder => $label, onValueChanged => 'clearResult',
                   minValue => N($o{min} // 0), maxValue => N($max)), align => 'JUSTIFY');
}

sub result_placeholder {
    return O(type => 'Box', id => 'result', children => [ button('Preview', 'preview') ]);
}

sub good_address { my ($a) = @_; return (defined $a && !ref $a && $a =~ /^[1-9A-HJ-NP-Za-km-z]{40,60}\z/) ? $a : undef }

# The start screen asks for the address first. It is an input like any other, so it is posted
# along when a button leads on, and the form shows it already chosen; "Mint another" brings it back.
sub home_view {
    my $addr = good_address(posted_values()->{address});
    return column([
        label('SigmaMint', 'HEADLINE1', color => 'PRIMARY'),
        label('Create your own token or NFT on Ergo', 'BODY2', color => 'SECONDARY', talign => 'CENTER'),
        child(card(column([
            child(label('Your wallet address', 'BODY1BOLD'), align => 'START'),
            O(type => 'ErgoAddressChooseButton', id => 'address', value => $addr, onValueChanged => 'home',
              style => $addr ? 'BUTTON_SECONDARY' : undef),
            child(label('What you mint arrives at this address, and it pays the network fee.', 'BODY2', color => 'SECONDARY'), align => 'START'),
        ], padding => 'DEFAULT', spacing => 'HALF_DEFAULT')), align => 'JUSTIFY'),
        child(card(column([
            child(label('Token', 'HEADLINE2'), align => 'START'),
            child(label('A token you can send, trade or give away: points, tickets, a community coin. '
                        . 'You choose the name, how many exist, and the decimals.', 'BODY1'), align => 'START'),
            button('Mint a token', 'goToken'),
        ], padding => 'DEFAULT', spacing => 'HALF_DEFAULT')), align => 'JUSTIFY'),
        child(card(column([
            child(label('NFT', 'HEADLINE2'), align => 'START'),
            child(label('A one-of-a-kind token linked to a picture, sound or video.', 'BODY1'), align => 'START'),
            button('Mint an NFT', 'goNft', style => 'SECONDARY'),
        ], padding => 'DEFAULT', spacing => 'HALF_DEFAULT')), align => 'JUSTIFY'),
        label('Minting costs only the Ergo network fee. Anyone can mint a token with any name: a name does not '
              . 'make a token official. Your wallet signs; SigmaMint never holds your funds.',
              'BODY2', color => 'SECONDARY', talign => 'CENTER'),
    ], id => 'main', padding => 'DEFAULT', spacing => 'DEFAULT');
}

sub form_view {
    my ($v, $result) = @_;
    my $addr = (defined $v->{address} && !ref $v->{address} && $v->{address} =~ /^[1-9A-HJ-NP-Za-km-z]{40,60}\z/) ? $v->{address} : undef;
    my @kids = (
        label('SigmaMint', 'HEADLINE1', color => 'PRIMARY'),
        child(row([ child(label($KIND eq 'nft' ? 'Mint an NFT' : 'Mint a token', 'HEADLINE2'), weight => N(1)),
                    button('Change', 'home', style => 'TEXT') ]), align => 'JUSTIFY'),
        child(card(column([
            child(label('Your wallet address', 'BODY1BOLD'), align => 'START'),
            O(type => 'ErgoAddressChooseButton', id => 'address', value => $addr, onValueChanged => 'clearResult',
              style => $addr ? 'BUTTON_SECONDARY' : undef),
            child(label('The new ' . ($KIND eq 'nft' ? 'NFT' : 'tokens') . ' will arrive at this address.', 'BODY2', color => 'SECONDARY'), align => 'START'),
        ], padding => 'DEFAULT', spacing => 'HALF_DEFAULT')), align => 'JUSTIFY'),
    );
    my @form = (
        child(label('Name', 'BODY1BOLD'), align => 'START'),
        text_field('name', $KIND eq 'nft' ? 'Name of the NFT' : 'Token name', trim($v->{name}), 40, min => 1),
        child(label('Description (optional)', 'BODY1BOLD'), align => 'START'),
        text_field('description', 'What is it for?', trim($v->{description}), 300),
    );
    if ($KIND eq 'token') {
        my $amount = (defined $v->{amount} && !ref $v->{amount} && "$v->{amount}" =~ /^[1-9]\d{0,18}\z/) ? "$v->{amount}" : undef;
        my $dec    = (defined $v->{decimals} && !ref $v->{decimals} && "$v->{decimals}" =~ /^[0-9]\z/) ? "$v->{decimals}" : '0';
        push @form,
            child(label('How many', 'BODY1BOLD'), align => 'START'),
            child(O(type => 'IntegerInputField', id => 'amount', value => defined $amount ? N($amount) : undef,
                    placeholder => 'Number of tokens', onValueChanged => 'clearResult', minValue => N(1)), align => 'JUSTIFY'),
            child(label('Decimals', 'BODY1BOLD'), align => 'START'),
            child(O(type => 'DropDownList', id => 'decimals', value => $dec, onValueChanged => 'clearResult',
                    entries => O(map { $_ => ($_ == 0 ? '0 (whole tokens only)' : "$_") } 0 .. 9)), align => 'JUSTIFY'),
            child(label('Decimals let a token be split, like cents. 0 is right for tickets and collectibles.',
                        'BODY2', color => 'SECONDARY'), align => 'START');
    }
    else {
        my $file = load_record(session_key($SESSION));
        push @form, child(label('Picture, sound or video', 'BODY1BOLD'), align => 'START');
        if ($file && $file->{cid}) {
            push @form, child(label("\x{2713} " . ucfirst($file->{media}) . ' added', 'BODY1', color => 'PRIMARY'), align => 'START'),
                        button('Choose a different file', 'openWeb', style => 'TEXT');
        }
        else {
            push @form,
                button('Choose file', 'openWeb', style => 'SECONDARY'),
                child(label('This opens a page where you pick the file from your phone. When it says the file is '
                            . 'added, come back here and tap Preview.', 'BODY2', color => 'SECONDARY'), align => 'START');
        }
    }
    push @kids, child(card(column(\@form, padding => 'DEFAULT', spacing => 'HALF_DEFAULT')), align => 'JUSTIFY');
    push @kids, child($result || result_placeholder(), align => 'JUSTIFY');
    return column(\@kids, id => 'main', padding => 'DEFAULT', spacing => 'DEFAULT');
}

sub base_actions {
    return (
        # VALID, not NONE: the chosen address travels between the start screen and the forms.
        # The start screen has no other input, and the forms' other fields are ignored there.
        O(type => 'BackendRequestAction', url => "$API?action=form&k=token", id => 'goToken', postValues => 'VALID'),
        O(type => 'BackendRequestAction', url => "$API?action=form&k=nft",   id => 'goNft',   postValues => 'VALID'),
        O(type => 'BackendRequestAction', url => "$API?action=home",         id => 'home',    postValues => 'VALID'),
        O(type => 'BackendRequestAction', url => "$API?action=preview&k=$KIND&s=$SESSION", id => 'preview', postValues => 'VALID'),
        O(type => 'BrowserAction', url => "$BASE/?s=$SESSION", id => 'openWeb'),
        O(type => 'ChangeSiteAction', id => 'clearResult', newContent => O(view => result_placeholder())),
    );
}

sub mosaik_action { out_json(O(appVersion => N(APP_VERSION), action => $_[0])) }
sub mosaik_dialog { mosaik_action(O(type => 'DialogAction', id => 'msg', message => $_[0], positiveButtonText => 'OK')) }
sub mosaik_replace {
    my ($view, @extra) = @_;
    mosaik_action(O(type => 'ChangeSiteAction', id => 'show', newContent => O(actions => [ base_actions(), @extra ], view => $view)));
}

sub result_box {
    my ($rows) = @_;
    return O(type => 'Box', id => 'result',
             children => [ child(card(column($rows, padding => 'DEFAULT', spacing => 'HALF_DEFAULT')), hAlign => 'JUSTIFY') ]);
}

# ================================================================== Mosaik ==

sub act_app {
    out_json(O(
        manifest => O(
            appName => 'SigmaMint', appDescription => 'Mint your own tokens and NFTs on Ergo.',
            iconUrl => "$BASE/icon.png", appVersion => N(APP_VERSION), targetMosaikVersion => N(2),
            targetCanvasDimension => 'COMPACT_WIDTH', cacheLifetime => N(3600),
            notificationCheckUrl => "$API?action=notify",
        ),
        actions => [ base_actions() ],
        view    => home_view(),
    ));
}

sub act_home { mosaik_replace(home_view()) }
sub act_form { mosaik_replace(form_view(posted_values())) }

sub act_preview {
    my $v = posted_values();
    return mosaik_dialog('Choose your wallet address first.')
        unless defined $v->{address} && !ref $v->{address} && $v->{address} =~ /^[1-9A-HJ-NP-Za-km-z]{40,60}\z/;
    my %in = %$v;
    if ($KIND eq 'nft') {
        my $file = load_record(session_key($SESSION));
        return mosaik_dialog('Add your file first: tap "Choose file", pick it, then come back and tap Preview.')
            unless $file && $file->{cid};
        @in{qw(cid sha256 media)} = @$file{qw(cid sha256 media)};
    }
    my ($d, $err) = check_draft($KIND, \%in);
    return mosaik_dialog($err) unless $d;
    my $nonce = new_draft($d);
    return mosaik_dialog('Minting is unavailable right now. Please try again later.') unless $nonce;
    watch_add('mint', $nonce);    # so the wallet's notification check can report the outcome

    my $fee = cfg('MINER_FEE', 1100000) + 0;
    my @rows;
    if ($KIND eq 'nft') {
        push @rows, O(type => 'Image', url => cfg('IPFS_GATEWAY_URL', 'https://gateway.lighthouse.storage/ipfs') . "/$d->{cid}",
                      size => 'MEDIUM') if $d->{media} eq 'picture';
        push @rows, kv_row('NFT', $d->{name}), kv_row('File', ucfirst $d->{media});
    }
    else {
        push @rows, kv_row('Token', $d->{name}),
                    kv_row('Amount', fmt_amount($d->{amount}, $d->{decimals})),
                    kv_row('Decimals', "$d->{decimals}");
    }
    push @rows,
        kv_row('Network fee', fmt_amount($fee, 9) . ' ERG'),
        child(label('About 0.001 ERG also moves into the box that holds your new '
                    . ($KIND eq 'nft' ? 'NFT' : 'tokens') . '. It stays yours.', 'BODY2', color => 'SECONDARY'), align => 'START'),
        child(label('A mint cannot be undone or edited afterwards. Check the name and the numbers.', 'BODY2BOLD'), align => 'START'),
        button($KIND eq 'nft' ? 'Mint NFT' : 'Mint token', 'pay');
    mosaik_replace(result_box(\@rows),
        O(type => 'BackendRequestAction', url => "$API?action=status&k=$KIND&s=$SESSION&n=$nonce", id => 'status', postValues => 'NONE'),
        O(type => 'ErgoPayAction', id => 'pay', onFinished => 'status',
          url => 'ergopay://' . ergopay_host() . "/api.pl?action=ergopay&n=$nonce&addr=$v->{address}"));
}

sub mint_status {    # -> (state, record) ; states: none | waiting | pending | confirmed | failed | unknown | lost
    my ($nonce) = @_;
    my $rec = load_record($nonce) or return ('none');
    return ('waiting', $rec) unless $rec->{tx_id};
    my $r = chain('status', { tx_id => $rec->{tx_id}, watch_box => $rec->{watch_box}, mode => 'mint', address => $rec->{address} });
    return ('unknown', $rec) unless $r->{ok};
    my $state = $r->{state} // 'unknown';
    $state = 'lost' if $state eq 'unknown' && time - ($rec->{t_built} || time) > 180;
    return ($state, $rec);
}

sub act_status {
    my $nonce = $cgi->url_param('n');
    return mosaik_dialog('Unknown mint.') unless defined $nonce && $nonce =~ /^[0-9a-f]{32}\z/;
    my ($state, $rec) = mint_status($nonce);
    my $self  = O(type => 'BackendRequestAction', url => "$API?action=status&k=$KIND&s=$SESSION&n=$nonce", id => 'status', postValues => 'NONE');
    my $again = button('Refresh status', 'status', style => 'SECONDARY');
    my $back  = button('Back to the form', 'clearResult', style => 'TEXT');
    my $row   = sub { child(label($_[0], $_[1] || 'BODY1'), align => 'START') };
    my (@rows, @extra);

    if ($state eq 'none' || $state eq 'waiting') {
        @rows = ($row->('Waiting for your wallet', 'BODY1BOLD'),
                 $row->('Your wallet has not picked up this mint yet. If you cancelled signing, nothing happened.'), $again, $back);
    }
    elsif ($state eq 'confirmed') {
        my $web = cfg('EXPLORER_TOKEN_URL', 'https://explorer.ergoplatform.com/en/token/');
        push @extra, O(type => 'CopyClipboardAction', text => $rec->{token_id}, id => 'copyId'),
                     O(type => 'BrowserAction', url => $web . $rec->{token_id}, id => 'viewToken');
        @rows = ($row->('Minted', 'BODY1BOLD'), $row->('You now hold ' . describe($rec) . '.'),
                 $row->('Token ID', 'BODY2BOLD'),
                 child(label($rec->{token_id}, 'BODY2', color => 'SECONDARY'), align => 'START'),
                 button('Copy token ID', 'copyId', style => 'SECONDARY'),
                 button('View on explorer', 'viewToken', style => 'TEXT'),
                 button('Mint another', 'home', style => 'TEXT'));
    }
    elsif ($state eq 'pending') {
        @rows = ($row->('Mint submitted', 'BODY1BOLD'), $row->('Waiting for the next block (about two minutes).'), $again);
    }
    elsif ($state eq 'failed') {
        @rows = ($row->('The mint did not go through', 'BODY1BOLD'),
                 $row->('The funds it needed were spent by another transaction first. Nothing was lost. Preview again.'),
                 button('Preview again', 'preview'), $back);
    }
    elsif ($state eq 'lost') {
        @rows = ($row->('Not found on the network', 'BODY1BOLD'),
                 $row->("Your transaction never appeared. If you cancelled signing, nothing happened. Otherwise check your wallet's history before trying again."),
                 $again, $back);
    }
    else {
        @rows = ($row->('Waiting for the network', 'BODY1BOLD'),
                 $row->('Your transaction has not shown up yet. This can take a moment after signing.'), $again, $back);
    }
    mosaik_replace(result_box(\@rows), $self, @extra);
}

sub act_notify {
    notify_json(notifications('mint', sub {
        my ($it) = @_;
        my ($state, $rec) = mint_status($it->{n});
        $rec ||= $it;
        return (1, 'Minted: you now hold ' . describe($rec) . '.')                   if $state eq 'confirmed';
        return (1, 'Your mint of ' . describe($rec) . ' did not go through. Nothing was lost.') if $state eq 'failed';
        return (1) if $state =~ /^(none|lost)\z/;
        return (0);
    }));
}

# ================================================================= ErgoPay ==

sub ergopay_error { out_json(O(message => $_[0], messageSeverity => 'ERROR')) }

sub act_ergopay {
    my $nonce = $cgi->param('n');
    my $addr  = $cgi->param('addr');
    return ergopay_error('Invalid request.')
        unless defined $nonce && $nonce =~ /^[0-9a-f]{32}\z/ && defined $addr && $addr =~ /^[1-9A-HJ-NP-Za-km-z]{40,60}\z/;
    my $d = load_record($nonce) or return ergopay_error('This mint request has expired. Start again in SigmaMint.');
    return ergopay_error('This mint request is not valid. Start again in SigmaMint.') unless ($d->{app} // '') eq 'mint';
    return ergopay_error('This mint was already submitted. Start a new one in SigmaMint.')
        if $d->{tx_id} && (mint_status($nonce))[0] =~ /^(pending|confirmed)\z/;

    my $r = chain('mint', { map({ $_ => $d->{$_} } qw(kind name description amount decimals cid sha256 media)), address => $addr });
    return ergopay_error($r->{error} || 'The mint could not be prepared. Please try again.') unless $r->{ok};
    save_record($nonce, { %$d, tx_id => $r->{tx_id}, token_id => $r->{token_id}, watch_box => $r->{watch_box},
                          address => $r->{address}, t_built => time });
    warn "sigmamint: built $d->{kind} mint tx $r->{tx_id}\n";    # audit trail, public data only
    out_json(O(
        reducedTx       => $r->{reduced_tx},
        address         => $r->{address},
        message         => 'SigmaMint: mint ' . describe($d) . '. Network fee ' . fmt_amount($r->{miner_fee}, 9)
                           . ' ERG. This cannot be undone.',
        messageSeverity => 'INFORMATION',
    ));
}

# ============================================================ browser page ==

sub uploads_enabled { return (cfg('LIGHTHOUSE_API_KEY') && cfg('MINT_UPLOADS', 1) && cache_dir()) ? 1 : 0 }

sub web_session {    # the session id the page was opened with (FormData field s), if it is a valid one
    my $s = $cgi->param('s');
    return session_ok($s) ? $s : undef;
}

sub web_config {
    success_json(uploads => N(uploads_enabled() && web_session() ? 1 : 0), max_mb => N($MAX_MB));
}

# Upload limits: uploads cost the operator's storage quota, so cap them per visitor
# and per day. Counters live in one small file; visitor addresses are kept only as
# a salted hash for the current day.
sub upload_allowed {
    my ($bytes, $count_it) = @_;    # asked twice: before the upload (may it?) and after it worked (count it)
    my $file = File::Spec->catfile(cache_dir(), 'mint-limits.json');
    open(my $fh, '+>>', $file) or return 0;
    flock($fh, LOCK_EX) or return 0;
    seek($fh, 0, 0);
    local $/;
    my $d = eval { JSON::PP->new->utf8->decode(scalar(<$fh>) || '{}') };
    $d = {} unless ref $d eq 'HASH';
    my @t    = gmtime;
    my $day  = sprintf('%04d%02d%02d', $t[5] + 1900, $t[4] + 1, $t[3]);
    my $hour = $t[2];
    $d = { day => $day, count => 0, bytes => 0, who => {} } unless ($d->{day} // '') eq $day && ref $d->{who} eq 'HASH';
    my $who = substr(sha256_hex("$day|" . ($ENV{REMOTE_ADDR} || '?')), 0, 16);
    my $w   = $d->{who}{$who};
    $w = { hour => $hour, n => 0, day => ($w && ref $w eq 'HASH' ? ($w->{day} // 0) : 0) }
        unless ref $w eq 'HASH' && ($w->{hour} // -1) == $hour;

    my $ok = $w->{n} < (cfg('MINT_UPLOADS_PER_HOUR', 10) + 0)
          && ($w->{day} // 0) < (cfg('MINT_UPLOADS_PER_VISITOR_DAY', 30) + 0)
          && $d->{count} < (cfg('MINT_UPLOADS_PER_DAY', 300) + 0)
          && $d->{bytes} + $bytes <= (cfg('MINT_UPLOAD_MB_PER_DAY', 1000) + 0) * 1024 * 1024;
    if ($ok && $count_it) {    # only uploads that were accepted count: junk cannot use up the allowance
        $w->{n}++;
        $w->{day} = ($w->{day} // 0) + 1;
        $d->{who}{$who} = $w;
        $d->{count}++;
        $d->{bytes} += $bytes;
        seek($fh, 0, 0);
        truncate($fh, 0);
        print {$fh} JSON::PP->new->utf8->encode($d);
    }
    close $fh;
    return $ok;
}

sub web_upload {
    return die_json('Uploads are not available.') unless uploads_enabled();
    my $session = web_session()
        or return die_json('This page has expired. Go back to SigmaMint in your Ergo wallet and tap "Choose file" again.');
    my $fh = $cgi->upload('file') or return die_json('No file received.');
    my $tmp = $cgi->tmpFileName($fh);
    return die_json('No file received.') unless defined $tmp && -f $tmp;
    my $size = -s $tmp;
    return die_json('The file is empty.') unless $size;
    return die_json("The file is too large (limit $MAX_MB MB).") if $size > $MAX_MB * 1024 * 1024;
    return die_json('Too many uploads right now. Please try again later.') unless upload_allowed($size, 0);

    my $r = chain('upload', { path => $tmp, key => cfg('LIGHTHOUSE_API_KEY'), max_bytes => $MAX_MB * 1024 * 1024 }, 150);
    return die_json($r->{error} || 'The upload failed. Please try again.') unless $r->{ok};
    upload_allowed($size, 1);
    warn "sigmamint: uploaded $r->{media} $r->{cid} ($r->{size} bytes)\n";    # security log: no file names, no key
    # attach the file to the wallet session: the wallet picks it up from here, nothing to copy
    save_record(session_key($session), { cid => $r->{cid}, sha256 => $r->{sha256}, media => $r->{media}, t => time });
    return die_json('The file could not be attached. Please try again.') unless load_record(session_key($session));
    success_json(media => $r->{media});
}

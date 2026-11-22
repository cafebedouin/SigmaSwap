#!/usr/bin/perl
# SigmaLP - add and remove liquidity on the ErgoDex pools, from the Ergo wallet.
# A subdirectory app of SigmaSwap (shared config, helper, venv, cache):
#   https://<host>/cgi-bin/sigmaswap/sigmalp/
#
#   Mosaik
#     GET  api.pl                    -> start screen: wallet address, then "Add liquidity" / "Your positions"
#     POST api.pl?action=add         -> the add form        ?action=addq  -> preview + button
#          (either amount may be typed; addq&side=&lx=&ly= says what the last preview showed)
#     POST api.pl?action=pos         -> choose address       ?action=posq  -> positions + withdraw buttons
#          (the address chosen on the start screen travels with every screen; with one, pos is posq)
#     POST api.pl?action=status&n=   -> what happened        GET ?action=notify -> wallet notification check
#   ErgoPay
#     GET  api.pl?action=ergopay&op=add|remove&...
#
# Like a swap, each change is ONE transaction straight against the pool box, built
# unsigned here and signed in the user's wallet. Public, no login, no keys.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use CGI ();
use JSON::PP ();
use Math::BigInt;
use File::Spec;
use AppConfig qw(cfg base_url chain);
use MosaikKit;

use constant APP_VERSION => 4;
use constant ERG         => '0' x 64;
use constant TOLERANCE   => 100;     # basis points the pool may move between preview and signing

$CGI::POST_MAX        = 64 * 1024;
$CGI::DISABLE_UPLOADS = 1;

my $cgi = CGI->new;
print $cgi->header(-type => 'application/json', -charset => 'utf-8', -cache_control => 'no-store');

my $BASE = base_url('sigmalp');
my $API  = "$BASE/api.pl";

my $action = $cgi->url_param('action');
$action = $cgi->param('action') unless defined $action && $action ne '';
$action = '' unless defined $action;

my %mosaik = ('' => \&act_app, home => \&act_home, add => \&act_add, addq => \&act_addq,
              pos => \&act_pos, posq => \&act_posq, status => \&act_status);

# "Your positions" with an address already chosen: show them straight away
$action = 'posq' if $action eq 'pos' && good_address(posted_values()->{address});

if ($cgi->cgi_error) { die_json('Bad request') }
elsif ($action eq 'ergopay') {
    eval { act_ergopay(); 1 } or do { warn "sigmalp: ergopay failed: $@"; ergopay_error('Something went wrong. Please try again.') };
}
elsif ($action eq 'notify') {
    eval { act_notify(); 1 } or do { warn "sigmalp: notify failed: $@"; notify_json(undef, 0, 240) };
}
elsif (exists $mosaik{$action}) {
    eval { $mosaik{$action}->(); 1 } or do { warn "sigmalp: '$action' failed: $@"; mosaik_dialog('Something went wrong. Please try again.') };
}
else { die_json('Unknown action') }
exit;

# ================================================================= helpers ==

sub posted_values {
    my $raw = $cgi->param('POSTDATA');
    return {} unless defined $raw && length $raw;
    my $v = eval { JSON::PP->new->utf8->decode($raw) };
    return ref $v eq 'HASH' ? $v : {};
}

sub good_address { my ($a) = @_; return (defined $a && !ref $a && $a =~ /^[1-9A-HJ-NP-Za-km-z]{40,60}\z/) ? $a : undef }
sub ergopay_host { my $h = $BASE; $h =~ s{^https?://}{}; return $h }
sub fmt_pct      { my $s = sprintf('%.2f', $_[0] / 100); $s =~ s/0+\z//; $s =~ s/\.\z//; return "$s %" }

# name + decimals of a token: the swap list's label when it has one, else what the chain says
sub tinfo {
    my ($reg, $id, $fallback) = @_;
    my $t = $reg->{tokens}{$id};
    return { ticker => $t->{label}, decimals => $t->{decimals} } if $t;
    return { ticker => 'ERG', decimals => 9 } if $id eq ERG;
    # not in the swap list: the name is whatever its creator chose, so the id always goes with it
    my $short = substr($id, 0, 6) . "\x{2026}";
    return (ref $fallback eq 'HASH' && defined $fallback->{ticker})
        ? { ticker => "$fallback->{ticker} ($short, unlisted)", decimals => ($fallback->{decimals} || 0) + 0 }
        : { ticker => "token $short (unlisted)", decimals => 0 };
}
sub amt { my ($raw, $t) = @_; return fmt_amount($raw, $t->{decimals}) . " $t->{ticker}" }

# An amount for the screen. A token is shown as a TokenLabel: the wallet adds its own
# verified/unverified badge and opens the token's details on tap, which a name alone cannot do.
sub amount_el {
    my ($id, $raw, $t) = @_;
    return amt($raw, $t) if $id eq ERG;
    return O(type => 'TokenLabel', tokenId => $id, tokenName => $t->{ticker},
             decimals => $t->{decimals} ? N($t->{decimals}) : undef, amount => N($raw), style => 'BODY1BOLD');
}

sub pool_list {    # [pool id, "ERG / SigUSD"] by liquidity
    my ($reg) = @_;
    my (%seen, @l);
    for my $p (sort { $b->{tvl} <=> $a->{tvl} } map { values %$_ } values %{ $reg->{pair} }) {
        next if $seen{ $p->{id} }++;
        push @l, [ $p->{id}, $reg->{tokens}{ $p->{x}{id} }{label} . ' / ' . $reg->{tokens}{ $p->{y}{id} }{label}, $p ];
    }
    return \@l;
}

sub lp_map {    # {LP token id => pool id}, cached for a day (it only grows when pools are created)
    my $cd   = cache_dir();
    my $file = $cd ? File::Spec->catfile($cd, 'lpmap.json') : undef;
    my $read = sub {
        open(my $fh, '<', $file) or return undef;
        local $/;
        my $d = eval { JSON::PP->new->utf8->decode(scalar <$fh>) };
        close $fh;
        return (ref $d eq 'HASH' && %$d) ? $d : undef;
    };
    if ($file && -f $file && time - (stat $file)[9] < 86400) { my $d = $read->(); return $d if $d }
    my $r = chain('lpmap', {}, 90);
    if ($r->{ok} && ref $r->{map} eq 'HASH' && %{ $r->{map} }) {
        if ($file && open(my $fh, '>', "$file.$$")) {
            print {$fh} JSON::PP->new->utf8->encode($r->{map});
            close $fh;
            rename("$file.$$", $file) or unlink "$file.$$";
        }
        return $r->{map};
    }
    return ($file && -f $file) ? ($read->() || {}) : {};
}

sub scale {    # n * bps / 10000, rounded down (scalar on purpose: bdiv returns two values in list context)
    my ($n, $bps_num) = @_;
    my $q = Math::BigInt->new("$n")->bmul($bps_num)->bdiv(10000);
    return $q;
}

# ============================================================ Mosaik views ==

sub base_actions {
    return (
        # VALID, not NONE: the chosen address goes back to the start screen with the user
        O(type => 'BackendRequestAction', url => "$API?action=home", id => 'home',   postValues => 'VALID'),
        O(type => 'BackendRequestAction', url => "$API?action=add",  id => 'goAdd',  postValues => 'VALID'),
        O(type => 'BackendRequestAction', url => "$API?action=pos",  id => 'goPos',  postValues => 'VALID'),
        O(type => 'BackendRequestAction', url => "$API?action=addq", id => 'preview', postValues => 'VALID'),
        O(type => 'BackendRequestAction', url => "$API?action=posq", id => 'positions', postValues => 'VALID'),
        O(type => 'ChangeSiteAction', id => 'clearResult',
          newContent => O(view => O(type => 'Box', id => 'result', children => [ button('Preview', 'preview') ]))),
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
sub header_rows {
    my ($title) = @_;
    return (label('SigmaLP', 'HEADLINE1', color => 'PRIMARY'),
            child(row([ child(label($title, 'HEADLINE2'), weight => N(1)), button('Change', 'home', style => 'TEXT') ]), align => 'JUSTIFY'));
}
sub address_card {
    my ($addr, $on_change, $note) = @_;
    return child(card(column([
        child(label('Your wallet address', 'BODY1BOLD'), align => 'START'),
        O(type => 'ErgoAddressChooseButton', id => 'address', value => $addr, onValueChanged => $on_change,
          style => $addr ? 'BUTTON_SECONDARY' : undef),
        defined $note ? child(label($note, 'BODY2', color => 'SECONDARY'), align => 'START') : (),
    ], padding => 'DEFAULT', spacing => 'HALF_DEFAULT')), align => 'JUSTIFY');
}

# The start screen asks for the address first. It is an input like any other, so it is posted
# along when a button leads on, and each screen shows it again: chosen once, kept everywhere.
# Coming back from a status screen there is no input to post, so that link names it (addr=).
sub home_view {
    my $addr = good_address(posted_values()->{address}) || good_address($cgi->url_param('addr'));
    return column([
        label('SigmaLP', 'HEADLINE1', color => 'PRIMARY'),
        label('Provide liquidity to the ErgoDex pools', 'BODY2', color => 'SECONDARY', talign => 'CENTER'),
        address_card($addr, 'home', $addr ? undef : 'Choose it once here. It is used for your positions and for adding liquidity.'),
        child(card(column([
            child(label('Add liquidity', 'HEADLINE2'), align => 'START'),
            child(label('Put two tokens into a pool, in the pool\'s current ratio. You receive LP tokens that stand '
                        . 'for your share, and your share earns the pool\'s trading fees.', 'BODY1'), align => 'START'),
            child(row([
                O(type => 'Icon', icon => 'WARN', size => 'SMALL', tintColor => 'PRIMARY'),
                child(label('When the price moves, the pool rebalances: you get back a different mix of the two '
                            . 'tokens than you put in, which can be worth less than simply holding them.',
                            'BODY2', color => 'PRIMARY'), weight => N(1)),
            ], spacing => 'HALF_DEFAULT'), align => 'JUSTIFY'),
            button('Add liquidity', 'goAdd'),
        ], padding => 'DEFAULT', spacing => 'HALF_DEFAULT')), align => 'JUSTIFY'),
        child(card(column([
            child(label('Your positions', 'HEADLINE2'), align => 'START'),
            child(label('See what your LP tokens are worth right now, and withdraw part or all of it.', 'BODY1'), align => 'START'),
            button('Your positions', 'goPos', style => 'SECONDARY'),
        ], padding => 'DEFAULT', spacing => 'HALF_DEFAULT')), align => 'JUSTIFY'),
        label('Each change is one transaction with the pool, signed in your wallet. Network fee '
              . fmt_amount(cfg('MINER_FEE', 1100000), 9) . ' ERG. No service fee.', 'BODY2', color => 'SECONDARY', talign => 'CENTER'),
    ], id => 'main', padding => 'DEFAULT', spacing => 'DEFAULT');
}

sub add_view {
    my ($reg, $v) = @_;
    my $addr  = good_address($v->{address});
    my $pools = pool_list($reg);
    my ($sel) = grep { defined $v->{pool} && !ref $v->{pool} && $_->[0] eq $v->{pool} } @$pools;
    return column([
        header_rows('Add liquidity'),
        address_card($addr, 'clearResult'),
        child(card(column([
            child(label('Pool', 'BODY1BOLD'), align => 'START'),
            child(O(type => 'DropDownList', id => 'pool', value => $sel ? $sel->[0] : undef, onValueChanged => 'goAdd',
                    placeholder => 'Select pool', entries => O(map { $_->[0] => $_->[1] } @$pools)), align => 'JUSTIFY'),
        ], padding => 'DEFAULT', spacing => 'HALF_DEFAULT')), align => 'JUSTIFY'),
        child(amounts_view($reg, $v, $sel), align => 'JUSTIFY'),
    ], id => 'main', padding => 'DEFAULT', spacing => 'DEFAULT');
}

# The two amounts and the preview under them are one element ('amounts'). A preview replaces just
# that: the fields come back filled in and the rest of the screen, and its scroll position, stay.
sub amounts_view {
    my ($reg, $v, $sel, $result) = @_;
    my (@form, @kids);
    if ($sel) {
        my $x = tinfo($reg, $sel->[2]{x}{id});
        my $y = tinfo($reg, $sel->[2]{y}{id});
        for my $f ([ ax => $x ], [ ay => $y ]) {    # ids carry the decimals: the wallet posts raw units
            my ($pre, $t) = @$f;
            my $val = typed_amount($v, "${pre}_$t->{decimals}");
            push @form,
                child(label("Amount of $t->{ticker}", 'BODY1BOLD'), align => 'START'),
                child(O(type => 'DecimalInputField', id => "${pre}_$t->{decimals}", value => defined $val ? N($val) : undef,
                        placeholder => "How much $t->{ticker} to add", onValueChanged => 'clearResult', onImeAction => 'preview',
                        imeActionType => 'DONE', minValue => N(1), scale => N($t->{decimals})), align => 'JUSTIFY');
        }
        push @form, child(label("Type either amount. Preview fills in the other from the pool's current price.",
                                'BODY2', color => 'SECONDARY'), align => 'START');
        push @kids, child(card(column(\@form, padding => 'DEFAULT', spacing => 'HALF_DEFAULT')), align => 'JUSTIFY');
    }
    push @kids, child($result || O(type => 'Box', id => 'result', children => [ $sel ? button('Preview', 'preview') : () ]), align => 'JUSTIFY');
    return column(\@kids, id => 'amounts', spacing => 'DEFAULT');
}

sub typed_amount {    # a posted amount field, as a string of raw units, or undef
    my ($v, $key) = @_;
    my $a = $v->{$key};
    return (defined $a && !ref $a && "$a" =~ /^[1-9]\d{0,18}\z/) ? "$a" : undef;
}

# Which of the two amounts did the user type? After a preview both fields are filled in, so the
# preview action's URL carries what that preview showed (lx, ly) and the side it was worked out
# from: the field that no longer matches is the one that was typed.
# -> 'x' | 'y' | '' (both were changed) | undef (nothing entered)
sub typed_side {
    my ($ax, $ay) = @_;
    return undef unless defined $ax || defined $ay;
    return 'x' unless defined $ay;
    return 'y' unless defined $ax;
    my ($lx, $ly, $last) = map { my $p = $cgi->url_param($_); defined $p ? $p : '' } qw(lx ly side);
    my ($cx, $cy) = ($ax ne $lx, $ay ne $ly);
    return ''  if $cx && $cy;
    return 'x' if $cx;
    return 'y' if $cy;
    return $last eq 'y' ? 'y' : 'x';
}

sub pos_view {
    my ($v, $result) = @_;
    my $addr = good_address($v->{address});
    return column([
        header_rows('Your positions'),
        address_card($addr, 'positions'),
        child($result || O(type => 'Box', id => 'result', children => [ button('Show my positions', 'positions') ]), align => 'JUSTIFY'),
    ], id => 'main', padding => 'DEFAULT', spacing => 'DEFAULT');
}

# ================================================================= actions ==

sub act_app {
    out_json(O(
        manifest => O(
            appName => 'SigmaLP', appDescription => 'Add and remove liquidity on the ErgoDex pools.',
            iconUrl => "$BASE/icon.png", appVersion => N(APP_VERSION), targetMosaikVersion => N(2),
            targetCanvasDimension => 'COMPACT_WIDTH', cacheLifetime => N(3600),
            notificationCheckUrl => "$API?action=notify",
        ),
        actions => [ base_actions() ],
        view    => home_view(),
    ));
}
sub act_home { mosaik_replace(home_view()) }
sub act_add {    # a fresh form (also after choosing another pool): the second amount starts empty
    my $v = posted_values();
    delete @$v{ grep { /^ay_/ } keys %$v };
    mosaik_replace(add_view(registry(), $v));
}
sub act_pos  { mosaik_replace(pos_view(posted_values())) }

sub sign_actions {    # (ErgoPayAction, its status action) tied together by a fresh note id
    my ($id, $url) = @_;
    my $nonce = new_nonce();
    my $ok = defined $nonce && record_file($nonce);
    my ($addr) = $url =~ /&addr=([1-9A-HJ-NP-Za-km-z]{40,60})\z/;    # so "Done" can lead back with it
    my @a;
    if ($ok) {
        $url .= "&n=$nonce";
        watch_add('lp', $nonce);
        push @a, O(type => 'BackendRequestAction', url => "$API?action=status&n=$nonce" . ($addr ? "&addr=$addr" : ''),
                   id => "st_$id", postValues => 'NONE');
    }
    push @a, O(type => 'ErgoPayAction', url => $url, id => $id, onFinished => $ok ? "st_$id" : 'home');
    return @a;
}

sub act_addq {
    my $reg  = registry();
    my $v    = posted_values();
    my $addr = good_address($v->{address});
    my ($sel) = grep { defined $v->{pool} && !ref $v->{pool} && $_->[0] eq $v->{pool} } @{ pool_list($reg) };
    return mosaik_dialog('Choose a pool.') unless $sel;
    my $x   = tinfo($reg, $sel->[2]{x}{id});
    my ($kx, $ky) = ("ax_$x->{decimals}", 'ay_' . tinfo($reg, $sel->[2]{y}{id})->{decimals});
    my $side = typed_side(typed_amount($v, $kx), typed_amount($v, $ky));
    return mosaik_dialog('Enter how much you want to add, of either token.') unless defined $side;
    return mosaik_dialog('Both amounts were changed. Clear one of them: it is worked out from the other.') if $side eq '';
    my $amt = typed_amount($v, $side eq 'y' ? $ky : $kx);

    my $q = chain('lpquote', { pool => $sel->[0], action => 'add', side => $side, amount => $amt, address => $addr });
    return mosaik_dialog($q->{error} || 'Could not get a quote. Please try again.') unless $q->{ok};
    my $y   = tinfo($reg, $q->{y}, $q->{y_info});
    my $fee = cfg('MINER_FEE', 1100000) + 0;
    my @rows = (
        kv_row("You add", amount_el($q->{x}, $q->{x_in}, $x)),
        kv_row("and", amount_el($q->{y}, $q->{y_in}, $y)),
        kv_row('Your share of the pool', '+' . ($q->{share_bps} >= 1 ? fmt_pct($q->{share_bps}) : 'less than 0.01 %')),
        kv_row('Pool fee you earn a share of', fmt_pct((1000 - $q->{fee_num}) * 10)),
        kv_row('Network fee', fmt_amount($fee, 9) . ' ERG'),
        child(label('You receive LP tokens for your share. Keep them: they are what you hand back to withdraw. '
                    . 'If the price moves you get back a different mix of the two tokens.', 'BODY2', color => 'SECONDARY'), align => 'START'),
    );
    my @extra;
    my $short;
    if ($addr && defined $q->{x_balance}) {
        my $need_x = Math::BigInt->new($q->{x_in});
        $need_x->badd($fee + 1000000) if $q->{x} eq ERG;
        $short = "Not enough $x->{ticker}: this address holds " . amt($q->{x_balance}, $x) . '.'
            if $need_x->bcmp(Math::BigInt->new($q->{x_balance})) > 0;
        $short ||= "Not enough $y->{ticker}: this address holds " . amt($q->{y_balance}, $y) . '.'
            if Math::BigInt->new($q->{y_in})->bcmp(Math::BigInt->new($q->{y_balance})) > 0;
    }
    if    (!$addr) { push @rows, label('Choose your wallet address above to continue.', 'BODY1', talign => 'CENTER') }
    elsif ($short) { push @rows, label($short, 'BODY1', talign => 'CENTER') }
    else {
        # the typed amount is taken exactly; the other one may grow by the tolerance, not more
        my $max_other = scale($side eq 'y' ? $q->{x_in} : $q->{y_in}, 10000 + TOLERANCE)->badd(1)->bstr;
        my $min_lp = scale($q->{lp_out}, 10000 - TOLERANCE)->bstr;
        $min_lp = '1' if $min_lp eq '0';
        push @extra, sign_actions('pay', 'ergopay://' . ergopay_host()
                                  . "/api.pl?action=ergopay&op=add&p=$sel->[0]&s=$side&a=$amt&q1=$max_other&q2=$min_lp&addr=$addr");
        push @rows, button('Add liquidity', 'pay');
    }
    push @rows, button('Refresh', 'preview', style => 'TEXT');
    # the amounts come back with both filled in; from here on "Preview" knows what was shown
    @$v{ $kx, $ky } = @$q{qw(x_in y_in)};
    mosaik_replace(amounts_view($reg, $v, $sel, result_box(\@rows)), @extra,
        O(type => 'BackendRequestAction', url => "$API?action=addq&side=$side&lx=$q->{x_in}&ly=$q->{y_in}", id => 'preview', postValues => 'VALID'));
}

sub act_posq {
    my $reg  = registry();
    my $v    = posted_values();
    my $addr = good_address($v->{address}) or return mosaik_dialog('Choose your wallet address first.');
    my $r = chain('lppositions', { address => $addr, map => lp_map() }, 90);
    return mosaik_dialog($r->{error} || 'Could not load your positions. Please try again.') unless $r->{ok};

    my (@rows, @extra);
    my $i = 0;
    for my $p (@{ $r->{positions} || [] }) {
        next unless ($p->{pool} // '') =~ /^[0-9a-f]{64}\z/ && ($p->{lp_amount} // '') =~ /^[1-9]\d*\z/;
        $i++;
        my $x = tinfo($reg, $p->{x}, $p->{x_info});
        my $y = tinfo($reg, $p->{y}, $p->{y_info});
        push @rows, O(type => 'HorizontalRule', vPadding => 'QUARTER_DEFAULT') if $i > 1;
        push @rows,
            child(label("$x->{ticker} / $y->{ticker}", 'BODY1BOLD'), align => 'START'),
            kv_row('Worth now', amount_el($p->{x}, $p->{x_out}, $x)),
            kv_row('and', amount_el($p->{y}, $p->{y_out}, $y)),
            ($p->{share_bps} >= 1 ? kv_row('Your share of the pool', fmt_pct($p->{share_bps})) : ());
        my @buttons;
        for my $pct (25, 50, 100) {
            my $lp = $pct == 100 ? Math::BigInt->new($p->{lp_amount}) : scale($p->{lp_amount}, $pct * 100);
            next if $lp->is_zero;
            my $min_x = scale(scale($p->{x_out}, $pct * 100), 10000 - TOLERANCE);
            my $min_y = scale(scale($p->{y_out}, $pct * 100), 10000 - TOLERANCE);
            next if $min_x->is_zero || $min_y->is_zero;
            push @extra, sign_actions("w${i}_$pct", 'ergopay://' . ergopay_host() . "/api.pl?action=ergopay&op=remove&p=$p->{pool}&a="
                                      . $lp->bstr . '&q1=' . $min_x->bstr . '&q2=' . $min_y->bstr . "&addr=$addr");
            push @buttons, child(button($pct == 100 ? 'All' : "$pct %", "w${i}_$pct", style => 'SECONDARY'), weight => N(1));
        }
        push @rows, child(label('Withdraw', 'BODY2', color => 'SECONDARY'), align => 'START'),
                    child(row(\@buttons, spacing => 'HALF_DEFAULT'), align => 'JUSTIFY') if @buttons;
    }
    push @rows, child(label('No liquidity positions on this address.', 'BODY1'), align => 'START') unless $i;
    push @rows, child(label('Amounts change with the pool price; the exact figures are shown in your wallet before you sign.',
                            'BODY2', color => 'SECONDARY'), align => 'START') if $i;
    push @rows, button('Refresh', 'positions', style => 'TEXT');
    mosaik_replace(pos_view($v, result_box(\@rows)), @extra);
}

sub describe_change {
    my ($rec) = @_;
    my $x = { ticker => $rec->{x_ticker} // '?', decimals => $rec->{x_dec} // 0 };
    my $y = { ticker => $rec->{y_ticker} // '?', decimals => $rec->{y_dec} // 0 };
    return ($rec->{action} eq 'add' ? 'added ' : 'withdrew ') . amt($rec->{x_amount}, $x) . ' + ' . amt($rec->{y_amount}, $y);
}

sub act_status {
    my $nonce = $cgi->url_param('n');
    return mosaik_dialog('Unknown request.') unless defined $nonce && $nonce =~ /^[0-9a-f]{32}\z/;
    my $addr  = good_address($cgi->url_param('addr'));
    my $with  = $addr ? "&addr=$addr" : '';
    my $self  = O(type => 'BackendRequestAction', url => "$API?action=status&n=$nonce$with", id => 'status', postValues => 'NONE');
    my $back  = O(type => 'BackendRequestAction', url => "$API?action=home$with", id => 'done', postValues => 'NONE');
    my $again = button('Refresh status', 'status', style => 'SECONDARY');
    my $home  = button('Done', 'done', style => 'TEXT');
    my $row   = sub { child(label($_[0], $_[1] || 'BODY1'), align => 'START') };
    my $rec   = load_record($nonce);
    my @rows;
    if (!$rec) {
        @rows = ($row->('Waiting for your wallet', 'BODY1BOLD'),
                 $row->('Your wallet has not picked this up yet. If you cancelled signing, nothing happened.'), $again, $home);
    }
    else {
        my $r  = chain('status', { tx_id => $rec->{tx_id}, watch_box => $rec->{watch_box}, mode => 'lp', address => $rec->{address} });
        my $st = $r->{ok} ? ($r->{state} // 'unknown') : 'unknown';
        if    ($st eq 'confirmed') { @rows = ($row->('Done', 'BODY1BOLD'), $row->('You ' . describe_change($rec) . '.'), $home) }
        elsif ($st eq 'pending')   { @rows = ($row->('Submitted', 'BODY1BOLD'), $row->('Waiting for the next block (about two minutes).'), $again) }
        elsif ($st eq 'failed')    { @rows = ($row->('It did not go through', 'BODY1BOLD'),
                                              $row->('Someone else used this pool first. Nothing was spent. Please try again.'), $home) }
        elsif (time - ($rec->{t} || time) < 180) {
            @rows = ($row->('Waiting for the network', 'BODY1BOLD'), $row->('Your transaction has not shown up yet. This can take a moment after signing.'), $again, $home);
        }
        else {
            @rows = ($row->('Not found on the network', 'BODY1BOLD'),
                     $row->("If you cancelled signing, nothing happened. Otherwise check your wallet's history before trying again."), $again, $home);
        }
    }
    mosaik_replace(column([ label('SigmaLP', 'HEADLINE1', color => 'PRIMARY'), child(result_box(\@rows), align => 'JUSTIFY') ],
                          id => 'main', padding => 'DEFAULT', spacing => 'DEFAULT'), $self, $back);
}

sub act_notify {
    notify_json(notifications('lp', sub {
        my ($it) = @_;
        my $r = chain('status', { tx_id => $it->{tx_id}, watch_box => $it->{watch_box}, mode => 'lp', address => $it->{address} });
        return (0) unless $r->{ok};
        my $st = $r->{state} // 'unknown';
        return (1, 'Liquidity: you ' . describe_change($it) . '.')                         if $st eq 'confirmed';
        return (1, 'Your liquidity change did not go through. Nothing was spent.')         if $st eq 'failed';
        return (1) if $st eq 'unknown' && time - ($it->{t} || 0) > 86400;
        return (0);
    }));
}

# ================================================================= ErgoPay ==

sub ergopay_error { out_json(O(message => $_[0], messageSeverity => 'ERROR')) }

sub act_ergopay {
    my %p = map { $_ => scalar $cgi->param($_) } qw(op p a q1 q2 addr n s);
    return ergopay_error('Invalid request.')
        unless defined $p{op} && $p{op} =~ /^(add|remove)\z/ && defined $p{p} && $p{p} =~ /^[0-9a-f]{64}\z/
            && good_address($p{addr}) && !grep { !defined $p{$_} || $p{$_} !~ /^[1-9]\d{0,18}\z/ } qw(a q1 q2);
    # an add names the amount of X, or of Y with s=y; q1 caps the other token
    my $side   = (defined $p{s} && $p{s} eq 'y') ? 'y' : 'x';
    my %limits = $p{op} ne 'add' ? (min_x => $p{q1}, min_y => $p{q2})
               : (side => $side, ($side eq 'y' ? 'max_x' : 'max_y') => $p{q1}, min_lp => $p{q2});
    # Adding liquidity puts the user's funds INTO a pool, so only pools from the published list:
    # a link must never steer deposits into a look-alike pool somebody set up. Withdrawing only
    # returns the user's own share to them, so that stays possible for any pool.
    if ($p{op} eq 'add') {
        my ($listed) = grep { $_->[0] eq $p{p} } @{ pool_list(registry()) };
        return ergopay_error('This pool is not available for adding liquidity.') unless $listed;
    }
    my $r = chain('lpbuild', { action => $p{op}, pool => $p{p}, amount => $p{a}, address => $p{addr}, %limits });
    return ergopay_error($r->{error} || 'This could not be prepared. Please try again.') unless $r->{ok};

    my $reg = registry();
    my $x = tinfo($reg, $r->{x}, $r->{x_info});
    my $y = tinfo($reg, $r->{y}, $r->{y_info});
    my %rec = (app => 'lp', t => time, mode => 'lp', action => $p{op}, tx_id => $r->{tx_id}, watch_box => $r->{watch_box}, address => $r->{address},
               x_amount => $r->{x_amount}, y_amount => $r->{y_amount}, x_ticker => $x->{ticker}, y_ticker => $y->{ticker},
               x_dec => $x->{decimals}, y_dec => $y->{decimals});
    save_record($p{n}, \%rec) if defined $p{n} && $p{n} =~ /^[0-9a-f]{32}\z/ && note_is_ours($p{n}, 'lp');
    warn "sigmalp: built $p{op} tx $r->{tx_id} pool " . substr($p{p}, 0, 8) . "\n";    # audit trail, public data only
    out_json(O(
        reducedTx       => $r->{reduced_tx},
        address         => $r->{address},
        message         => ($p{op} eq 'add'
                               ? 'SigmaLP: add ' . amt($r->{x_amount}, $x) . ' and ' . amt($r->{y_amount}, $y) . " to the $x->{ticker} / $y->{ticker} pool."
                               : 'SigmaLP: withdraw ' . amt($r->{x_amount}, $x) . ' and ' . amt($r->{y_amount}, $y) . " from the $x->{ticker} / $y->{ticker} pool.")
                           . ' Network fee ' . fmt_amount($r->{miner_fee}, 9) . ' ERG.',
        messageSeverity => 'INFORMATION',
    ));
}

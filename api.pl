#!/usr/bin/perl
# SigmaSwap - Mosaik swap app for the ErgoDex liquidity pools.
#
# One action-routed CGI. It speaks three small protocols:
#
#   Mosaik (Ergo wallet in-app dApps)
#     GET  api.pl                    -> MosaikApp JSON (the whole view)
#     POST api.pl?action=refresh     -> re-render the form from the posted input values
#          (&max=1: with the amount set to the address's whole balance of the pay token)
#     POST api.pl?action=flip        -> same, with pay/receive tokens exchanged
#     POST api.pl?action=quote       -> price the swap, show details + Swap button
#     POST api.pl?action=orders      -> list the address's open swap orders (cancel buttons)
#     POST api.pl?action=home        -> the start screen (wallet address, then direct swap or order)
#     POST api.pl?action=status&n=   -> what happened to the swap/order just signed
#   (&mode=direct|order on every Mosaik action says which of the two screens is open)
#   ErgoPay (EIP-20), fetched by the wallet when the user taps Swap
#     GET  api.pl?action=ergopay&... -> { reducedTx, address, message, messageSeverity }
#          (a direct swap; with &o=1 an order; with &r=<box id> the refund of an order)
#   Landing page (index.html / app.js), POST FormData like every other AAP app
#     POST api.pl  action=pools      -> { success: 1, pools: [...] }
#     POST api.pl  action=health     -> { success: 1, ... }   (deploy gate)
#
# The app is public: no login, no database, no cookies, no keys. The only thing it
# stores is a short-lived note of each transaction it built (public data), so it
# can tell the user afterwards whether the swap went through.
# The server only ever builds an UNSIGNED transaction; the user's wallet shows
# it, and signs it or not. All chain work happens in sigmaswap.py.

use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use CGI ();
use JSON::PP ();
use Math::BigInt;
use Math::BigFloat;
use File::Spec;
use AppConfig qw(cfg base_url chain);
use MosaikKit;

use constant APP_VERSION => 12;     # bump when the Mosaik view changes: open wallets reload
use constant ERG         => '0' x 64;
use constant SLIPPAGE    => (50 => '0.5 %', 100 => '1 %', 300 => '3 %', 1000 => '10 %');

$CGI::POST_MAX        = 64 * 1024;
$CGI::DISABLE_UPLOADS = 1;

# set (with local) while a quote is built for embedding in a full screen, see act_hop2
our ($CAPTURE, $NO_SHORT);

my $cgi = CGI->new;
# The JSON header MUST be the first thing printed.
print $cgi->header(-type => 'application/json', -charset => 'utf-8', -cache_control => 'no-store');

my $BASE = base_url();
my $API  = "$BASE/api.pl";

my $action = $cgi->url_param('action');
$action = $cgi->param('action') unless defined $action && $action ne '';
$action = '' unless defined $action;

# 'direct' or 'order': which of the two swap screens the user is on (carried in the action URLs)
my $MODE = $cgi->url_param('mode');
# A limit order is an order with a price of the user's choosing: same machinery, its own screen.
my $LIMIT = (defined $MODE && $MODE eq 'limit') ? 1 : 0;
$MODE = 'order' if $LIMIT;
$MODE = 'direct' unless defined $MODE && $MODE eq 'order';
my $MODE_Q = $LIMIT ? 'limit' : $MODE;    # how the current screen is named in action URLs

# Simple mode: the same swap with only the essentials on screen. It is chosen with
# the switch on the start screen (posted once as an input value) and from then on
# travels in the action URLs, like the mode.
my $SIMPLE = $cgi->url_param('simple');
if (defined $SIMPLE) { $SIMPLE = $SIMPLE eq '1' ? 1 : 0 }
else {
    my $v = posted_values();
    $SIMPLE = exists $v->{simple} ? ($v->{simple} ? 1 : 0) : (cfg('SIMPLE_DEFAULT', 0) ? 1 : 0);
}

my %actions = (
    ''        => \&act_app,
    'refresh' => \&act_refresh,
    'flip'    => \&act_flip,
    'quote'   => \&act_quote,
    'orders'  => \&act_orders,
    'home'    => \&act_home,
    'status'  => \&act_status,
    'hop2'    => \&act_hop2,
    'ergopay' => \&act_ergopay,
    'pools'   => \&act_pools,
    'health'  => \&act_health,
    'notify'  => \&act_notify,
);

if ($cgi->cgi_error) {
    die_json('Bad request');
}
elsif (exists $actions{$action}) {
    my $ok = eval { $actions{$action}->(); 1 };
    if (!$ok) {
        my $err = $@ || 'unknown error';
        $err =~ s/\s+\z//;
        warn "sigmaswap: action '$action' failed: $err\n";     # detail to the log only
        if    ($action eq 'ergopay')                  { ergopay_error('Something went wrong. Please try again.') }
        elsif ($action =~ /^(refresh|flip|quote|orders|home|status|hop2)\z/) { mosaik_dialog('Something went wrong. Please try again.') }
        else                                          { die_json('Something went wrong') }
    }
}
else {
    die_json('Unknown action');
}
exit;

# (JSON encoder, Mosaik view helpers and the note store live in MosaikKit.pm)


# ================================================================= amounts ==


sub fmt_rate {    # "1 FROM ~ x TO", six significant digits
    my ($in, $din, $out, $dout) = @_;
    return undef unless $in =~ /^\d+\z/ && $in > 0;
    my $r = Math::BigFloat->new("$out")->bmul(Math::BigFloat->new(10)->bpow($din))
        ->bdiv(Math::BigFloat->new("$in")->bmul(Math::BigFloat->new(10)->bpow($dout)), 40);
    return '0' if $r->is_zero;
    my $s = $r->bround(6)->bstr;
    $s =~ s/0+\z// if $s =~ /\./;
    $s =~ s/\.\z//;
    return $s;
}

sub fmt_pct {    # basis points -> "0.32 %"
    my ($bps) = @_;
    my $s = sprintf('%.2f', $bps / 100);
    $s =~ s/0+\z//;
    $s =~ s/\.\z//;
    return "$s %";
}

# =================================================================== pools ==
# The liquid-pool list is cached in a small JSON file (outside the app tree in
# production) so that opening the app does not hit the ErgoDex API every time.


# ============================================================ input values ==

sub posted_values {
    my $raw = $cgi->param('POSTDATA');
    return {} unless defined $raw && length $raw;
    my $v = eval { JSON::PP->new->utf8->decode($raw) };
    return ref $v eq 'HASH' ? $v : {};
}

# Two tokens with no pool of their own can still be swapped through ERG: A -> ERG -> B.
# A pool must be the first output of its transaction, so two pools can never share
# one. Instead the first swap is direct and its ERG goes straight into an order for
# B, which a bot completes: one signature. Offered on the direct screen only.
sub can_hop {
    my ($reg, $from, $to) = @_;
    my $erg = ERG;
    return 0 unless $MODE eq 'direct' && defined $from && defined $to;
    return 0 if $from eq $erg || $to eq $erg || $from eq $to || $reg->{pair}{$from}{$to};
    return ($reg->{pair}{$from}{$erg} && $reg->{pair}{$erg}{$to}) ? 1 : 0;
}

# Everything the wallet posts is untrusted: keep only well-formed, known values.
sub clean_state {
    my ($v, $reg) = @_;
    my %s;
    my $addr = $v->{address};
    $s{address} = $addr if defined $addr && !ref $addr && $addr =~ /^[1-9A-HJ-NP-Za-km-z]{40,60}\z/;
    for my $k (qw(from to)) {
        my $id = $v->{$k};
        $s{$k} = $id if defined $id && !ref $id && exists $reg->{tokens}{$id};
    }
    $s{from} = ERG if !defined $s{from} && exists $reg->{tokens}{ +ERG };
    delete $s{to} if defined $s{to} && defined $s{from} && !$reg->{pair}{ $s{from} }{ $s{to} }
                     && !can_hop($reg, $s{from}, $s{to});
    if (defined $s{from}) {
        my $a = $v->{ 'amount_' . $reg->{tokens}{ $s{from} }{decimals} };
        $s{amount} = "$a" if defined $a && !ref $a && "$a" =~ /^[1-9]\d{0,18}\z/;
    }
    $s{sort} = (defined $v->{sort} && !ref $v->{sort} && $v->{sort} eq 'az') ? 'az' : 'liq';
    my %slip = SLIPPAGE;
    my $sl   = $v->{slippage};
    $s{slippage} = (defined $sl && !ref $sl && exists $slip{$sl}) ? $sl : 100;
    if ($LIMIT) {    # the user's price: receive-token per 1 pay-token, with 9 decimals
        my $p = $v->{price_9};
        $s{price} = "$p" if defined $p && !ref $p && "$p" =~ /^[1-9]\d{0,18}\z/;
    }
    if ($MODE eq 'order' && exists $reg->{tokens}{ +ERG }) {    # orders exist for ERG pairs only
        my $erg = ERG;
        $s{from} = $erg unless defined $s{from} && ($s{from} eq $erg || $reg->{pair}{ $s{from} }{$erg});
        if    ($s{from} ne $erg)                                       { $s{to} = $erg }
        elsif (defined $s{to} && !$reg->{pair}{$erg}{ $s{to} })        { delete $s{to} }
        delete $s{amount} unless defined $v->{ 'amount_' . $reg->{tokens}{ $s{from} }{decimals} };
    }
    return \%s;
}

# ============================================================ Mosaik views ==


# ERG locked in a pool, in nanoERG. ERG pools report it; for a token-token pool it is
# estimated from the pool's value (half of it is one side) and marked with "about".
sub erg_price {    # USD per ERG, from the deepest ERG pool
    my ($reg) = @_;
    return $reg->{erg_usd} if exists $reg->{erg_usd};
    my ($best) = sort { $b->{tvl} <=> $a->{tvl} } grep { $_->{erg} } values %{ $reg->{pair}{ +ERG } || {} };
    return $reg->{erg_usd} = $best ? $best->{tvl} / 2 / ($best->{erg} / 1e9) : 0;
}
sub pool_erg {    # -> (nanoERG, is_estimate) or ()
    my ($reg, $p) = @_;
    return ($p->{erg}, 0) if $p && $p->{erg};
    my $usd = erg_price($reg);
    return ($p->{tvl} / 2 / $usd * 1e9, 1) if $p && $usd > 0;
    return ();
}
sub fmt_liq {    # "12,340 ERG" / "~ 85 ERG"
    my ($nano, $est) = @_;
    my $erg = $nano / 1e9;
    my $n = $erg >= 100 ? sprintf('%.0f', $erg) : $erg >= 1 ? sprintf('%.1f', $erg) : sprintf('%.2f', $erg);
    1 while $n =~ s/^(\d+)(\d{3})/$1,$2/;
    return ($est ? "\x{2248} " : '') . "$n ERG";
}
# The pool a token is judged by: the one with the chosen other token, else its ERG
# pool, else its deepest pool.
sub token_pool {
    my ($reg, $id, $other) = @_;
    my $pairs = $reg->{pair}{$id} or return undef;
    return $pairs->{$other} if defined $other && $pairs->{$other};
    return $pairs->{ +ERG } if $pairs->{ +ERG };
    my ($best) = sort { $b->{tvl} <=> $a->{tvl} } values %$pairs;
    return $best;
}
sub token_dropdown {
    my ($id, $reg, $ids, $value, $placeholder, $sort, $other) = @_;
    my (%liq, %label);
    for my $t (@$ids) {
        my $name = $reg->{tokens}{$t}{label};
        my ($nano, $est) = ($t eq ERG && !defined $other) ? () : pool_erg($reg, token_pool($reg, $t, $other));
        $liq{$t}   = $nano // 9e99;      # ERG itself (no single pool) stays first
        $label{$t} = defined $nano ? "$name  \x{00B7}  " . fmt_liq($nano, $est) : $name;
        $label{$t} .= "  \x{00B7}  via ERG" if defined $other && can_hop($reg, $other, $t);
    }
    my @sorted = $sort eq 'az'
        ? sort { ($b eq ERG) <=> ($a eq ERG) || lc $reg->{tokens}{$a}{label} cmp lc $reg->{tokens}{$b}{label} || $a cmp $b } @$ids
        : sort { ($b eq ERG) <=> ($a eq ERG) || $liq{$b} <=> $liq{$a} || $a cmp $b } @$ids;
    return O(type => 'DropDownList', id => $id, value => $value, onValueChanged => 'refresh',
             placeholder => $placeholder, entries => O(map { $_ => $label{$_} } @sorted));
}

sub quote_placeholder {    # what the quote area shows before / after a preview
    my ($text) = @_;
    return O(type => 'Box', id => 'quote', children => [ button($text || ($MODE eq 'order' ? 'Preview order' : 'Preview swap'), 'preview') ]);
}

sub orders_placeholder {    # collapsed "open orders" area (needs an address)
    my ($address) = @_;
    return O(type => 'Box', id => 'orders',
             children => [ $address ? button('My open orders', 'orders', style => 'TEXT') : () ]);
}

sub title_block {
    return (
        label('SigmaSwap', 'HEADLINE1', color => 'PRIMARY'),
        label('Swap ERG and tokens on the ErgoDex liquidity pools', 'BODY2', color => 'SECONDARY', talign => 'CENTER'),
    );
}

# ---- home: the two ways to swap, each explained

sub home_view {
    my ($reg) = @_;
    my @kids = title_block();
    if (!@{ $reg->{order} }) {
        push @kids, label('The pool list is unavailable right now. Please try again in a moment.', 'BODY1', talign => 'CENTER'),
                    button('Retry', 'reload');
        return column(\@kids, id => 'main', padding => 'DEFAULT', spacing => 'DEFAULT');
    }
    my $order_fee = fmt_amount(cfg('ORDER_MIN_EX_FEE', 6000000), 9);

    # The address comes first. It is an input like any other, so it is posted along when a
    # button leads on and every screen shows it again: chosen once, kept everywhere.
    my $addr = posted_values()->{address};
    $addr = undef unless defined $addr && !ref $addr && $addr =~ /^[1-9A-HJ-NP-Za-km-z]{40,60}\z/;
    push @kids, child(card(column([
        child(label('Your wallet address', 'BODY1BOLD'), align => 'START'),
        O(type => 'ErgoAddressChooseButton', id => 'address', value => $addr, onValueChanged => 'homeAddr',
          style => $addr ? 'BUTTON_SECONDARY' : undef),
        $addr ? () : child(label('Choose it once here. Every swap screen uses it.', 'BODY2', color => 'SECONDARY'), align => 'START'),
    ], padding => 'DEFAULT', spacing => 'HALF_DEFAULT')), align => 'JUSTIFY');
    # orders already waiting are this address's funds: reachable without picking a swap type first
    push @kids, child(orders_placeholder($addr), align => 'JUSTIFY') if $addr;

    push @kids, child(card(column([
        child(label('Direct swap', 'HEADLINE2'), align => 'START'),
        child(label('One transaction between your wallet and the pool. You receive exactly the amount you are shown, '
                    . 'with no extra fee, and nobody can trade ahead of you.', 'BODY1'), align => 'START'),
        child(label('If someone else trades in the same pool at the same moment, your swap does not happen. '
                    . 'Nothing is spent, and you simply try again.', 'BODY2', color => 'SECONDARY'), align => 'START'),
        button('Direct swap', 'goDirect'),
    ], padding => 'DEFAULT', spacing => 'HALF_DEFAULT')), align => 'JUSTIFY');

    push @kids, child(card(column([
        child(label('Order', 'HEADLINE2'), align => 'START'),
        child(label('Your funds go into an ErgoDex order and a bot completes the swap for you, even when the pool '
                    . "is busy. Costs about $order_fee ERG extra. Pairs with ERG only. "
                    . 'You can cancel while it is waiting.', 'BODY1'), align => 'START'),
        child(row([
            O(type => 'Icon', icon => 'WARN', size => 'SMALL', tintColor => 'PRIMARY'),
            child(label('Warning: you can be front-run. A waiting order is public, so other traders can trade '
                        . 'ahead of it and you may receive only your minimum amount instead of the quoted one.',
                        'BODY2BOLD', color => 'PRIMARY'), weight => N(1)),
        ], spacing => 'HALF_DEFAULT'), align => 'JUSTIFY'),
        button('Place an order', 'goOrder', style => 'SECONDARY'),
    ], padding => 'DEFAULT', spacing => 'HALF_DEFAULT')), align => 'JUSTIFY');

    push @kids, child(card(column([
        child(label('Limit order', 'HEADLINE2'), align => 'START'),
        child(label('Name your own price. You see the current price and set yours above or below it. The order '
                    . 'waits until the pool reaches your price, then SigmaSwap completes it. Pairs with ERG only.',
                    'BODY1'), align => 'START'),
        child(label('It may never fill if the price does not get there. You can cancel it any time. Like any '
                    . 'waiting order it is public and can be front-run.', 'BODY2', color => 'SECONDARY'), align => 'START'),
        button('Limit order', 'goLimit', style => 'SECONDARY'),
    ], padding => 'DEFAULT', spacing => 'HALF_DEFAULT')), align => 'JUSTIFY');

    push @kids, child(card(column([
        child(O(type => 'CheckboxLabel', id => 'simple', text => 'Simple mode', style => 'BODY1BOLD',
                value => ($SIMPLE ? TRUE : FALSE)), align => 'START'),
        child(label('Shows only what you need: what you pay, what you receive, and the button. '
                    . 'Switch it off to see rate, price impact, fees and slippage settings.',
                    'BODY2', color => 'SECONDARY'), align => 'START'),
    ], padding => 'DEFAULT', spacing => 'HALF_DEFAULT')), align => 'JUSTIFY');

    push @kids, label('Your wallet signs every transaction; SigmaSwap never holds your funds.',
                      'BODY2', color => 'SECONDARY', talign => 'CENTER');
    return column(\@kids, id => 'main', padding => 'DEFAULT', spacing => 'DEFAULT');
}

# ---- the swap form of one mode

sub main_view {
    my ($reg, $s, $balance, $quote_box) = @_;
    my $tok   = $reg->{tokens};
    my $from  = defined $s->{from} ? $tok->{ $s->{from} } : undef;
    my $order = $MODE eq 'order';

    my @kids = title_block();
    if (!@{ $reg->{order} }) {
        push @kids, label('The pool list is unavailable right now. Please try again in a moment.', 'BODY1', talign => 'CENTER'),
                    button('Retry', 'reload');
        return column(\@kids, id => 'main', padding => 'DEFAULT', spacing => 'DEFAULT');
    }
    push @kids, child(row([
        child(label($LIMIT ? 'Limit order' : $order ? 'Order' : 'Direct swap', 'HEADLINE2'), weight => N(1)),
        button('Change', 'home', style => 'TEXT'),
    ]), align => 'JUSTIFY');
    push @kids, child(row([
        O(type => 'Icon', icon => 'WARN', size => 'SMALL', tintColor => 'PRIMARY'),
        child(label('A waiting order can be front-run: you may receive only your minimum amount.',
                    'BODY2', color => 'PRIMARY'), weight => N(1)),
    ], spacing => 'HALF_DEFAULT'), align => 'JUSTIFY') if $order;

    # ---- wallet
    push @kids, child(card(column([
        child(label('Your wallet address', 'BODY1BOLD'), align => 'START'),
        O(type => 'ErgoAddressChooseButton', id => 'address', value => $s->{address}, onValueChanged => 'refresh',
          style => $s->{address} ? 'BUTTON_SECONDARY' : undef),
        $SIMPLE ? () : child(label('Funds are taken from, and returned to, this address.', 'BODY2', color => 'SECONDARY'), align => 'START'),
    ], padding => 'DEFAULT', spacing => 'HALF_DEFAULT')), align => 'JUSTIFY');

    # ---- pay / receive (orders exist for ERG pairs only)
    my $erg      = ERG;
    my @from_ids = $order ? (grep { $_ eq $erg || $reg->{pair}{$_}{$erg} } @{ $reg->{order} }) : @{ $reg->{order} };
    my @to_ids   = !$from ? ()
                 : ($order && $from->{id} ne $erg) ? ($erg)
                 : (keys %{ $reg->{pair}{ $from->{id} } }, grep { can_hop($reg, $from->{id}, $_) } @{ $reg->{order} });
    my $sort = $s->{sort} || 'liq';
    my %slip = SLIPPAGE;
    my @form = (
        $SIMPLE ? () : (
            child(label('Sort tokens by', 'BODY1BOLD'), align => 'START'),
            child(O(type => 'DropDownList', id => 'sort', value => $sort, onValueChanged => 'refresh',
                    entries => O(liq => 'Most liquidity first', az => 'Name (A to Z)')), align => 'JUSTIFY'),
            child(label('The amount next to each token is the ERG held in its pool. A small pool means a worse '
                        . 'price, and a copy of a well-known token usually has a small pool.',
                        'BODY2', color => 'SECONDARY'), align => 'START'),
        ),
        child(label('You pay', 'BODY1BOLD'), align => 'START'),
        child(token_dropdown('from', $reg, \@from_ids, $s->{from}, 'Select token', $sort), align => 'JUSTIFY'),
    );
    if ($from) {
        # ERG is entered in the wallet's own amount field: the user can switch it to their fiat
        # currency, and the other of the two is shown underneath. Its value is nanoERG either way,
        # so nothing else changes. Without a fiat rate in the wallet it is a plain ERG field.
        my $is_erg = $from->{id} eq ERG;
        push @form, child(O(
            type => ($is_erg ? 'FiatOrErgAmountInputField' : 'DecimalInputField'), id => "amount_$from->{decimals}",
            value => defined $s->{amount} ? N($s->{amount}) : undef,
            placeholder => "Amount of $from->{ticker}",
            onValueChanged => 'clearQuote', onImeAction => 'preview', minValue => N(1),
            imeActionType => 'DONE', scale => ($is_erg ? undef : N($from->{decimals})),
        ), align => 'JUSTIFY');
        # A token balance can be put in whole with one tap. Not ERG: an address emptied of ERG
        # cannot pay for its next transaction.
        my $all = defined $balance && $from->{id} ne ERG && "$balance" =~ /^[1-9]\d{0,18}\z/;
        push @form, child(row([
            child(label('Balance: ' . fmt_amount($balance, $from->{decimals}) . " $from->{ticker}",
                        'BODY2', color => 'SECONDARY', talign => 'END'), weight => N(1)),
            $all ? button('Use all', 'useAll', style => 'TEXT') : (),
        ], spacing => 'HALF_DEFAULT'), align => 'JUSTIFY') if defined $balance;
    }
    push @form,
        button("\x{21C5}  Switch", 'flip', style => 'TEXT', enabled => (defined $s->{to} ? 1 : 0)),
        child(label('You receive', 'BODY1BOLD'), align => 'START'),
        child(token_dropdown('to', $reg, \@to_ids, $s->{to}, 'Select token', $sort, $from ? $from->{id} : undef), align => 'JUSTIFY');
    if ($LIMIT && $from && defined $s->{to}) {
        my $to = $tok->{ $s->{to} };
        push @form, child(label('Your price', 'BODY1BOLD'), align => 'START');
        push @form, child(label("Current price: 1 $from->{ticker} \x{2248} " . fmt_amount($s->{spot}, 9) . " $to->{ticker}",
                                'BODY1', color => 'PRIMARY'), align => 'START') if defined $s->{spot};
        push @form,
            child(O(type => 'DecimalInputField', id => 'price_9', value => defined $s->{price} ? N($s->{price}) : undef,
                    placeholder => "$to->{ticker} for 1 $from->{ticker}",
                    onValueChanged => 'clearQuote', onImeAction => 'preview', imeActionType => 'DONE',
                    minValue => N(1), scale => N(9)), align => 'JUSTIFY'),
            child(label("How much $to->{ticker} you want for each $from->{ticker}. It starts at the current price: raise it "
                        . 'and the order waits for a better price; lower it and it fills right away.',
                        'BODY2', color => 'SECONDARY'), align => 'START'),
            button('Use current price', 'resetPrice', style => 'TEXT');
    }
    # simple mode has no slippage control: the 1 % default applies
    push @form,
        child(label($order ? 'Slippage tolerance (sets your minimum)' : 'Slippage tolerance', 'BODY1BOLD'), align => 'START'),
        child(O(type => 'DropDownList', id => 'slippage', value => "$s->{slippage}", onValueChanged => 'clearQuote',
                entries => O(map { $_ => $slip{$_} } sort { $a <=> $b } keys %slip)), align => 'JUSTIFY')
        unless $SIMPLE || $LIMIT;    # a limit order's minimum is its price
    push @kids, child(card(column(\@form, padding => 'DEFAULT', spacing => 'HALF_DEFAULT')), align => 'JUSTIFY');

    # ---- quote / status area, open orders, footer
    push @kids, child($quote_box || quote_placeholder(), align => 'JUSTIFY');
    # a route through ERG leaves an order behind, so its screen needs the list too
    push @kids, child(orders_placeholder($s->{address}), align => 'JUSTIFY')
        if $order || ($from && can_hop($reg, $from->{id}, $s->{to}));
    push @kids, label('Network fee ' . fmt_amount(cfg('MINER_FEE', 1100000), 9) . ' ERG. No service fee. '
                      . 'Your wallet signs every transaction; SigmaSwap never holds your funds.',
                      'BODY2', color => 'SECONDARY', talign => 'CENTER') unless $SIMPLE;

    return column(\@kids, id => 'main', padding => 'DEFAULT', spacing => 'DEFAULT');
}

# Every response re-declares the actions with the current mode in their URLs: the
# mode is not an input field, it travels with the buttons.
sub base_actions {
    my $m = "&mode=$MODE_Q&simple=$SIMPLE";
    return (
        # from the start screen: no simple= in the URL, the switch itself is posted
        O(type => 'BackendRequestAction', url => "$API?action=refresh&mode=direct", id => 'goDirect', postValues => 'VALID'),
        O(type => 'BackendRequestAction', url => "$API?action=refresh&mode=order",  id => 'goOrder',  postValues => 'VALID'),
        O(type => 'BackendRequestAction', url => "$API?action=refresh&mode=limit",  id => 'goLimit',  postValues => 'VALID'),
        O(type => 'BackendRequestAction', url => "$API?action=refresh$m&reset=1",   id => 'resetPrice', postValues => 'VALID'),
        # VALID, not NONE: the chosen address goes back to the start screen with the user
        O(type => 'BackendRequestAction', url => "$API?action=home&simple=$SIMPLE", id => 'home',     postValues => 'VALID'),
        # the address was chosen on the start screen: no simple= here, the switch on that screen is posted
        O(type => 'BackendRequestAction', url => "$API?action=home",                id => 'homeAddr', postValues => 'VALID'),
        O(type => 'BackendRequestAction', url => "$API?action=refresh$m", id => 'refresh', postValues => 'VALID'),
        O(type => 'BackendRequestAction', url => "$API?action=flip$m",    id => 'flip',    postValues => 'VALID'),
        O(type => 'BackendRequestAction', url => "$API?action=quote$m",   id => 'preview', postValues => 'VALID'),
        O(type => 'BackendRequestAction', url => "$API?action=orders$m",  id => 'orders',  postValues => 'VALID'),
        O(type => 'BackendRequestAction', url => "$API?action=refresh$m&max=1", id => 'useAll', postValues => 'VALID'),
        O(type => 'ReloadAction', id => 'reload'),
        # local (no network): typing a new amount drops a quote that no longer matches it
        O(type => 'ChangeSiteAction', id => 'clearQuote', newContent => O(view => quote_placeholder())),
    );
}

sub mosaik_action { out_json(O(appVersion => N(APP_VERSION), action => $_[0])) }
sub mosaik_dialog {
    my ($msg) = @_;
    mosaik_action(O(type => 'DialogAction', id => 'msg', message => $msg, positiveButtonText => 'OK'));
}
sub mosaik_replace {    # ChangeSiteAction: the element with the same id is replaced in place
    my ($view, @extra_actions) = @_;
    mosaik_action(O(type => 'ChangeSiteAction', id => 'show',
                    newContent => O(actions => [ base_actions(), @extra_actions ], view => $view)));
}

# ================================================================= actions ==

sub act_app {
    my $reg = registry();
    out_json(O(
        manifest => O(
            appName               => 'SigmaSwap',
            appDescription        => 'Swap ERG and Ergo tokens on the ErgoDex liquidity pools.',
            iconUrl               => "$BASE/icon.png",
            appVersion            => N(APP_VERSION),
            targetMosaikVersion   => N(2),
            targetCanvasDimension => 'COMPACT_WIDTH',
            cacheLifetime         => N(3600),
            notificationCheckUrl  => "$API?action=notify",
        ),
        actions => [ base_actions() ],
        view    => home_view($reg),
    ));
}

sub act_home { mosaik_replace(home_view(registry())) }

sub lookup_balance {
    my ($s) = @_;
    return undef unless $s->{address} && $s->{from};
    my $r = chain('balance', { address => $s->{address}, token => $s->{from} });
    return $r->{ok} ? $r->{balance} : undef;
}

# Limit screen: read the pool's current price for the chosen pair (receive-token per
# 1 pay-token, 9 decimals, pool fee included) and start the price field from it.
sub fill_price {
    my ($reg, $s, $force) = @_;
    return unless $LIMIT && defined $s->{from} && defined $s->{to};
    my $pool = $reg->{pair}{ $s->{from} }{ $s->{to} } or return;
    my $q = chain('quote', { pool => $pool->{id}, from => $s->{from}, amount => $s->{amount} // '1' });
    return unless $q->{ok} && ($q->{reserve_in} // '') =~ /^[1-9]\d*\z/ && ($q->{reserve_out} // '') =~ /^\d+\z/;
    my ($df, $dt) = ($reg->{tokens}{ $s->{from} }{decimals}, $reg->{tokens}{ $s->{to} }{decimals});
    my $spot = Math::BigInt->new($q->{reserve_out})->bmul($q->{fee_num})->bmul(Math::BigInt->new(10)->bpow($df + 9));
    $spot = $spot->bdiv(Math::BigInt->new($q->{reserve_in})->bmul($q->{fee_denom})->bmul(Math::BigInt->new(10)->bpow($dt)));
    return if $spot->is_zero || length($spot->bstr) > 18;
    $s->{spot}  = $spot->bstr;
    $s->{price} = $spot->bstr if $force || !defined $s->{price};
}

sub act_refresh {
    my $reg = registry();
    my $s   = clean_state(posted_values(), $reg);
    fill_price($reg, $s, ($cgi->url_param('reset') // '') eq '1');
    my $balance = lookup_balance($s);
    $s->{amount} = "$balance"    # "Use all"
        if ($cgi->url_param('max') // '') eq '1' && defined $balance && $s->{from} ne ERG && "$balance" =~ /^[1-9]\d{0,18}\z/;
    mosaik_replace(main_view($reg, $s, $balance));
}

sub act_flip {
    my $reg = registry();
    my $s   = clean_state(posted_values(), $reg);
    if (defined $s->{from} && defined $s->{to}) {
        @$s{qw(from to)} = @$s{qw(to from)};
        delete $s->{amount};    # the amount was in units of the other token
    }
    fill_price($reg, $s, 1);    # the price is the other way round now
    mosaik_replace(main_view($reg, $s, lookup_balance($s)));
}

# ---- status of a submitted swap/order
# The wallet tells us nothing after signing, so each quote carries a random id.
# When the wallet fetches the transaction we note its id under that random id;
# afterwards the status screen looks the transaction up on the chain.


sub status_box {
    my ($title, $lines, $buttons) = @_;
    my @rows = (child(label($title, 'BODY1BOLD'), align => 'START'));
    push @rows, map { child(ref $_ ? $_ : label($_, 'BODY1'), align => 'START') } @$lines;
    push @rows, @$buttons;
    return O(type => 'Box', id => 'quote',
             children => [ child(card(column(\@rows, padding => 'DEFAULT', spacing => 'HALF_DEFAULT')), hAlign => 'JUSTIFY') ]);
}

sub act_status {
    my $nonce = $cgi->url_param('n');
    return mosaik_dialog('Unknown swap.') unless defined $nonce && $nonce =~ /^[0-9a-f]{32}\z/;
    my $reg    = registry();
    my $self   = O(type => 'BackendRequestAction', url => "$API?action=status&mode=$MODE_Q&simple=$SIMPLE&n=$nonce", id => 'status', postValues => 'NONE');
    my $again  = button('Refresh status', 'status', style => 'SECONDARY');
    my $new    = button('Back to the form', 'clearQuote', style => 'TEXT');
    my $what   = $MODE eq 'order' ? 'order' : 'swap';

    my $rec = load_record($nonce);
    my $hop = $rec && $rec->{hop};
    my $next = ($rec && ($rec->{next} // '') =~ /^[0-9a-f]{64}\z/) ? $reg->{tokens}{ $rec->{next} } : undef;
    if (!$rec) {
        return mosaik_replace(status_box("Waiting for your wallet", [
            "Your wallet has not picked up this $what yet. If you cancelled signing, nothing happened.",
        ], [ $again, $new ]), $self);
    }
    my $r = chain('status', { map { $_ => $rec->{$_} } qw(tx_id watch_box order_box mode address to) });
    return mosaik_dialog($r->{error} || 'Could not check the status. Please try again.') unless $r->{ok};

    my $summary = describe_amount($reg, $rec->{from}, $rec->{amount}) . " \x{2192} " . ($rec->{to} =~ /^[0-9a-f]{64}\z/ ? ($reg->{tokens}{ $rec->{to} }{ticker} // 'token') : 'token');
    my $web = cfg('EXPLORER_WEB_URL', 'https://explorer.ergoplatform.com/en/transactions/');
    my @extra = ($self, O(type => 'BrowserAction', url => $web . $rec->{tx_id}, id => 'viewTx'));
    my $view  = button('View transaction', 'viewTx', style => 'TEXT');
    my $age   = time - ($rec->{t} || time);
    my $state = $r->{state} // 'unknown';
    my ($title, @lines, @buttons);
    my $step2;
    if ($next) {
        push @extra, O(type => 'BackendRequestAction', url => "$API?action=hop2&mode=direct&simple=$SIMPLE&n=$nonce", id => 'hop2', postValues => 'VALID');
        $step2 = button('Step 2 of 2: swap ' . fmt_amount($rec->{out}, 9, 4) . " ERG for $next->{ticker}", 'hop2');
    }

    if ($state eq 'confirmed') {
        $title   = $next ? 'Step 1 of 2 complete' : 'Swap complete';
        @lines   = ($summary, 'You received ' . describe_amount($reg, $rec->{to}, $rec->{out}) . '.');
        push @lines, "Now swap that ERG for $next->{ticker} to finish." if $next;
        @buttons = ($next ? $step2 : (), $view, $new);
    }
    elsif ($state eq 'executed') {
        $title   = $hop ? 'Swap complete' : 'Order executed';
        @lines   = ($summary, defined $r->{received} ? 'You received ' . describe_amount($reg, $rec->{to}, $r->{received}) . '.'
                                                     : 'The bot completed your order.');
        @buttons = ($view, $new);
    }
    elsif ($state eq 'order_open' || $state eq 'executing') {
        $title   = $hop ? ($state eq 'executing' ? 'Second swap is being completed' : 'First swap done, second is waiting for a bot')
                 : $state eq 'executing' ? 'Order is being executed' : 'Order is waiting for a bot';
        @lines   = ($summary, ($hop ? 'Your tokens were swapped for ERG, and that ERG is in an order for the token you chose. ' : '')
                              . 'This usually takes a few minutes. If the price is below your minimum it waits; '
                              . 'you can cancel it under "My open orders"' . ($hop ? ' and take the ERG.' : '.'));
        @buttons = ($again, $view, $new);
    }
    elsif ($state eq 'cancelled') {
        $title   = 'Order cancelled';
        @lines   = ($summary, $hop ? 'The second swap was cancelled: the ERG from the first swap is back on your address.'
                                   : 'The order was refunded to your address.');
        @buttons = ($view, $new);
    }
    elsif ($state eq 'pending') {
        $title   = ($MODE eq 'order' && !$hop) ? 'Order submitted' : $next ? 'Step 1 of 2 submitted' : 'Swap submitted';
        @lines   = ($summary, 'Waiting for the next block (about two minutes).');
        push @lines, 'You can sign step 2 now, without waiting. If step 1 fails after all, step 2 fails with it and nothing is spent.' if $next;
        @buttons = ($next ? $step2 : (), $again, $view, $new);
    }
    elsif ($state eq 'failed') {
        $title   = ($MODE eq 'order' && !$hop) ? 'Order was not placed' : 'Swap did not go through';
        @lines   = ($summary, ($MODE eq 'order' && !$hop)
                        ? 'The funds it needed were spent by another transaction first. Nothing was lost. Preview again.'
                        : 'Someone else traded in this pool first. Nothing was spent. Preview again for a fresh price.');
        @buttons = (button('Preview again', 'preview'), $new);
    }
    elsif ($age < 180) {
        $title   = 'Waiting for the network';
        @lines   = ($summary, 'Your transaction has not shown up yet. This can take a moment after signing. '
                              . 'If you cancelled signing, nothing happened.');
        @buttons = ($again, $new);
    }
    else {
        $title   = 'Not found on the network';
        @lines   = ($summary, 'Your transaction never appeared. If you cancelled signing, nothing happened. '
                              . "Otherwise check your wallet's history before trying again.");
        @buttons = ($again, $new);
    }
    mosaik_replace(status_box($title, \@lines, \@buttons), @extra);
}

# A -> ERG -> B, one signature (see can_hop). The preview prices both swaps; the
# minimum the user agrees to is the minimum of B, enforced by the order contract.
sub hop_quote {
    my ($reg, $s) = @_;
    my $erg = ERG;
    my ($from, $to)     = @{ $reg->{tokens} }{ $s->{from}, $s->{to} };
    my ($pool1, $pool2) = ($reg->{pair}{ $s->{from} }{$erg}, $reg->{pair}{$erg}{ $s->{to} });
    my $q1 = chain('quote', { pool => $pool1->{id}, from => $s->{from}, amount => $s->{amount}, address => $s->{address} });
    return mosaik_dialog($q1->{error} || 'Could not get a quote. Please try again.') unless $q1->{ok};
    return mosaik_dialog('This pool no longer matches the selected pair. Please reopen the app.')
        unless $q1->{to} eq $erg && "$q1->{out}" =~ /^\d+\z/ && ref $q1->{order} eq 'HASH';
    my $order = $q1->{order};
    my $mid   = Math::BigInt->new($q1->{out})->bsub($order->{extra});    # ERG that goes on to the second swap
    return mosaik_dialog('This amount is too small for a route through ERG: the fees would eat it.')
        if $mid->bcmp(Math::BigInt->new($order->{max_ex_fee})->bmul(10)) < 0;
    my $q2 = chain('quote', { pool => $pool2->{id}, from => $erg, amount => $mid->bstr });
    return mosaik_dialog($q2->{error} || 'Could not get a quote. Please try again.') unless $q2->{ok};
    return mosaik_dialog('This pool no longer matches the selected pair. Please reopen the app.')
        unless $q2->{to} eq $s->{to} && "$q2->{out}" =~ /^\d+\z/;
    return mosaik_dialog('This amount is too small to swap on this route.') if $q2->{out} eq '0';

    my $min_out = Math::BigInt->new($q2->{out})->bmul(10000 - $s->{slippage})->bdiv(10000);
    $min_out = Math::BigInt->new(1) if $min_out->is_zero;
    my $ex_fee = Math::BigInt->new($order->{min_ex_fee})->bmul($q2->{out})->bdiv($min_out);
    $ex_fee = Math::BigInt->new($order->{max_ex_fee}) if $ex_fee->bcmp($order->{max_ex_fee}) > 0;
    my $fee = cfg('MINER_FEE', 1100000) + 0;
    my $bps = $q1->{impact_bps} + $q2->{impact_bps};
    my $get_el = O(type => 'TokenLabel', tokenId => $s->{to}, tokenName => $to->{ticker},
                   decimals => $to->{decimals} ? N($to->{decimals}) : undef, amount => N($q2->{out}),
                   style => 'HEADLINE2', textColor => 'PRIMARY');
    my $least = fmt_amount($min_out->bstr, $to->{decimals}) . " $to->{ticker}";
    my @rows = (
        O(type => 'Row', packed => TRUE, spacing => 'HALF_DEFAULT', children => [
            O(type => 'Image', url => icon_url($s->{from}), size => 'SMALL'),
            O(type => 'Icon', icon => 'FORWARD', size => 'SMALL', tintColor => 'SECONDARY'),
            O(type => 'Image', url => icon_url($erg), size => 'SMALL'),
            O(type => 'Icon', icon => 'FORWARD', size => 'SMALL', tintColor => 'SECONDARY'),
            O(type => 'Image', url => icon_url($s->{to}), size => 'SMALL'),
        ]),
        kv_row('You pay', fmt_amount($s->{amount}, $from->{decimals}) . " $from->{ticker}"),
        kv_row('You receive (estimate)', $get_el),
        kv_row('At least', $least),
    );
    if (!$SIMPLE) {
        push @rows,
            O(type => 'HorizontalRule', vPadding => 'HALF_DEFAULT'),
            kv_row('Route', "$from->{ticker} \x{2192} ERG \x{2192} $to->{ticker}"),
            kv_row('Through', "\x{2248} " . fmt_amount($q1->{out}, 9, 4) . ' ERG'),
            kv_row('Rate', "1 $from->{ticker} \x{2248} " . fmt_rate($s->{amount}, $from->{decimals}, $q2->{out}, $to->{decimals}) . " $to->{ticker}"),
            kv_row('Price impact (both pools)', fmt_pct($bps)),
            kv_row('Pool fees', fmt_pct(($q1->{fee_denom} - $q1->{fee_num}) * 10000 / $q1->{fee_denom}) . ' + '
                                . fmt_pct(($q2->{fee_denom} - $q2->{fee_num}) * 10000 / $q2->{fee_denom})),
            kv_row('Bot fee', "\x{2248} " . fmt_amount($ex_fee->bstr, 9, 4) . ' ERG (max ' . fmt_amount($order->{max_ex_fee}, 9) . ')'),
            kv_row('Network fee', fmt_amount($fee, 9) . ' ERG');
    }
    push @rows, child(label("No pool trades $from->{ticker} for $to->{ticker} directly, so this goes through ERG. You sign once. "
                            . "Your $from->{ticker} is swapped for ERG right away, and that ERG goes straight into an order for "
                            . "$to->{ticker}, which a bot completes a few minutes later at the pool price then, never below "
                            . "$least. A waiting order can be front-run down to that minimum. If the price drops below it the "
                            . 'order waits: cancel it under "My open orders" and you get the ERG back, not the '
                            . "$from->{ticker}.", 'BODY2', color => 'SECONDARY'), align => 'START');
    push @rows, child(label("Warning: this route moves the pool prices by " . fmt_pct($bps)
                            . ". You will receive noticeably less than the market rate.", 'BODY2BOLD', color => 'PRIMARY'),
                      align => 'START') if $bps >= 500;
    # the alternative: two direct swaps, signed one after the other. No bot, nothing waits.
    my $min1 = Math::BigInt->new($q1->{out})->bmul(10000 - $s->{slippage})->bdiv(10000);
    $min1 = Math::BigInt->new(1) if $min1->is_zero;
    return finish_quote($q1, $s, $from, $to, $pool1, $min_out, $fee, undef, \@rows, 0, hop => $pool2->{id},
                        alt => { min => $min1->bstr, next => $s->{to},
                                 button => 'Sign twice instead (no front-running)',
                                 note   => "Or do it as two direct swaps, $from->{ticker} \x{2192} ERG and then ERG \x{2192} "
                                           . "$to->{ticker}, each signed by you. No bot and no waiting order, so nothing can be "
                                           . 'front-run and there is no bot fee. Each swap completes exactly as shown or not at '
                                           . 'all. The price can still move between the two; if you stop after the first you '
                                           . 'hold ERG.' });
}

sub act_quote {
    my $reg = registry();
    run_quote($reg, clean_state(posted_values(), $reg));
}

# Second swap of a route the user chose to sign twice: the first swap (A -> ERG) is
# signed, now offer ERG -> B for exactly the ERG it paid out. All from our own note.
sub act_hop2 {
    my $nonce = $cgi->url_param('n');
    my $rec   = (defined $nonce && $nonce =~ /^[0-9a-f]{32}\z/) ? load_record($nonce) : undef;
    my $reg   = registry();
    return mosaik_dialog('This swap is no longer available. Start again from the form.')
        unless $rec && ($rec->{app} // '') eq 'swap' && ($rec->{to} // '') eq ERG && ($rec->{next} // '') =~ /^[0-9a-f]{64}\z/
            && $reg->{pair}{ +ERG }{ $rec->{next} } && ($rec->{out} // '') =~ /^[1-9]\d{0,18}\z/
            && ($rec->{address} // '') =~ /^[1-9A-HJ-NP-Za-km-z]{40,60}\z/;
    my %slip = SLIPPAGE;
    my $sl   = posted_values()->{slippage};
    my $s = { address => $rec->{address}, from => ERG, to => $rec->{next}, amount => $rec->{out}, sort => 'liq',
              slippage => (defined $sl && !ref $sl && exists $slip{$sl}) ? $sl : 100 };
    local $CAPTURE  = [];
    local $NO_SHORT = 1;    # the ERG from step 1 may still be unconfirmed; the builder checks for real
    run_quote($reg, $s);
    return unless @$CAPTURE;    # a dialog was sent instead
    my ($box, @extra) = @$CAPTURE;
    mosaik_replace(main_view($reg, $s, undef, $box), @extra);
}

sub run_quote {
    my ($reg, $s) = @_;
    return mosaik_dialog('Choose the token you want to pay with.')   unless defined $s->{from};
    return mosaik_dialog('Choose the token you want to receive.')    unless defined $s->{to};
    return mosaik_dialog('Enter the amount you want to swap.')       unless defined $s->{amount};

    return hop_quote($reg, $s) if can_hop($reg, $s->{from}, $s->{to});
    my $pool = $reg->{pair}{ $s->{from} }{ $s->{to} };
    my ($from, $to) = @{ $reg->{tokens} }{ $s->{from}, $s->{to} };
    if ($LIMIT) {    # the price becomes the order's minimum: amount x price, in the receive token's units
        return mosaik_dialog('Enter your price.') unless defined $s->{price};
        my $total = Math::BigInt->new($s->{amount})->bmul($s->{price})->bmul(Math::BigInt->new(10)->bpow($to->{decimals}));
        $total = $total->bdiv(Math::BigInt->new(10)->bpow($from->{decimals} + 9));
        return mosaik_dialog('At that price this amount buys less than the smallest unit. Raise the amount or the price.')
            if $total->is_zero;
        return mosaik_dialog('That price is too high for this amount.') if length($total->bstr) > 18;
        $s->{limit} = $total->bstr;
    }
    my $q = chain('quote', { pool => $pool->{id}, from => $s->{from}, amount => $s->{amount}, address => $s->{address} });
    return mosaik_dialog($q->{error} || 'Could not get a quote. Please try again.') unless $q->{ok};
    return mosaik_dialog('This pool no longer matches the selected pair. Please reopen the app.')
        unless $q->{to} eq $s->{to} && "$q->{out}" =~ /^\d+\z/;
    return mosaik_dialog('This amount is too small to swap in this pool.') if $q->{out} eq '0';

    my $min_out = Math::BigInt->new($q->{out})->bmul(10000 - $s->{slippage})->bdiv(10000);
    $min_out = Math::BigInt->new(1) if $min_out->is_zero;
    my $fee   = cfg('MINER_FEE', 1100000) + 0;
    my $bps   = $q->{impact_bps} + 0;

    # ---- order mode: the same swap, executed by an ErgoDex bot (ERG pairs only)
    my $order = ($MODE eq 'order' && ref $q->{order} eq 'HASH') ? $q->{order} : undef;
    return mosaik_dialog('Orders are only available for pairs with ERG. Go back and choose "Direct swap" for this pair.')
        if $MODE eq 'order' && !$order;
    # a limit replaces the slippage-based minimum; above today's price the order waits
    my $limit = ($order && defined $s->{limit}) ? Math::BigInt->new($s->{limit}) : undef;
    $min_out = $limit->copy if $limit;
    my $waits = ($limit && $limit->bcmp(Math::BigInt->new($q->{out})) > 0) ? 1 : 0;
    my ($show_out, $show_min, $ex_fee) = ($q->{out}, $min_out->bstr, undef);
    if ($order) {
        # the bot's fee grows with the output: min_ex_fee at the minimum output
        $ex_fee = Math::BigInt->new($order->{min_ex_fee})->bmul($q->{out})->bdiv($min_out);
        $ex_fee = Math::BigInt->new($order->{max_ex_fee}) if $ex_fee->bcmp($order->{max_ex_fee}) > 0;
        if ($s->{to} eq ERG) {    # fee comes out of the ERG received
            return mosaik_dialog('This amount is too small for an order: the execution fee would eat it. '
                                 . 'Choose "Direct swap" instead.')
                if $min_out->bcmp(Math::BigInt->new($order->{max_ex_fee})->bmul(3)) < 0;
            $show_out = Math::BigInt->new($q->{out})->bsub($ex_fee)->bstr;
            $show_min = $min_out->copy->bsub($order->{min_ex_fee})->bstr;
        }
    }

    my $pay  = fmt_amount($s->{amount}, $from->{decimals}) . " $from->{ticker}";
    my $get  = fmt_amount($show_out,    $to->{decimals})   . " $to->{ticker}";
    my $rate = fmt_rate($s->{amount}, $from->{decimals}, $q->{out}, $to->{decimals});

    # the received amount as a TokenLabel: the wallet adds its own verified/unverified
    # badge and opens the token details on tap
    my $get_el = $s->{to} eq ERG
        ? label($get, 'HEADLINE2', color => 'PRIMARY', talign => 'END')
        : O(type => 'TokenLabel', tokenId => $s->{to}, tokenName => $to->{ticker},
            decimals => $to->{decimals} ? N($to->{decimals}) : undef, amount => N($show_out),
            style => 'HEADLINE2', textColor => 'PRIMARY');

    my @rows = (
        # the two token logos, pay -> receive
        O(type => 'Row', packed => TRUE, spacing => 'DEFAULT', children => [
            O(type => 'Image', url => icon_url($s->{from}), size => 'SMALL'),
            O(type => 'Icon', icon => 'FORWARD', size => 'MEDIUM', tintColor => 'SECONDARY'),
            O(type => 'Image', url => icon_url($s->{to}), size => 'SMALL'),
        ]),
        kv_row('You pay', $pay),
        kv_row($order ? 'You receive (estimate)' : 'You receive', $get_el),
    );
    if ($SIMPLE) {
        # the essentials only; an order still shows the two things that differ from the estimate
        push @rows, kv_row('At least', fmt_amount($show_min, $to->{decimals}) . " $to->{ticker}"),
                    kv_row('Bot fee', "\x{2248} " . fmt_amount($ex_fee->bstr, 9, 4) . ' ERG') if $order;
    }
    else {
        push @rows, detail_rows($q, $s, $from, $to, $rate, $bps, $fee, $order, $ex_fee, $show_min);
    }
    push @rows, child(label("Warning: this swap moves the pool price by " . fmt_pct($bps)
                            . ". You will receive noticeably less than the market rate.", 'BODY2BOLD', color => 'PRIMARY'),
                      align => 'START') if $bps >= 500;
    if ($waits) {    # a waiting limit order: say plainly what it is
        @rows = (
            $rows[0],
            kv_row('You pay', $pay),
            kv_row('You receive at least', fmt_amount($limit->bstr, $to->{decimals}) . " $to->{ticker}", style => 'HEADLINE2', color => 'PRIMARY'),
            (defined $s->{price} ? kv_row('Your price', "1 $from->{ticker} = " . fmt_amount($s->{price}, 9) . " $to->{ticker}") : ()),
            kv_row("Today's price would give", fmt_amount($q->{out}, $to->{decimals}) . " $to->{ticker}"),
            child(label('This is a limit order. It waits until the pool can pay your limit; SigmaSwap checks every '
                        . 'minute and completes it then. It may never fill if the price does not get there. You can '
                        . 'cancel it any time under "My open orders". A fee deposit of ' . fmt_amount($order->{extra}, 9)
                        . ' ERG is locked with it; the unused part comes back when it fills or when you cancel.',
                        'BODY2', color => 'SECONDARY'), align => 'START'),
        );
    }
    push @rows, child(label('Your price is at or below the current price, so this fills right away, at the current '
                            . 'price and never below yours.', 'BODY2', color => 'SECONDARY'), align => 'START')
        if $LIMIT && !$waits;
    return finish_quote($q, $s, $from, $to, $pool, $min_out, $fee, $order, \@rows, $limit ? 1 : 0);
}

# Token logos are bundled PNGs (icons/<token id>.png, built by tools/fetch_icons.py);
# a token without one gets the generic placeholder.
sub icon_path {
    my ($id) = @_;
    return ($id =~ /^[0-9a-f]{64}\z/ && -f "$FindBin::Bin/icons/$id.png") ? "icons/$id.png" : 'icons/unknown.png';
}
sub icon_url { return "$BASE/" . icon_path($_[0]) }

sub detail_rows {
    my ($q, $s, $from, $to, $rate, $bps, $fee, $order, $ex_fee, $show_min) = @_;
    my @rows = (
        O(type => 'HorizontalRule', vPadding => 'HALF_DEFAULT'),
        kv_row('Rate', "1 $from->{ticker} \x{2248} $rate $to->{ticker}"),
        kv_row('Price impact', fmt_pct($bps)),
        kv_row('Pool fee', fmt_pct(($q->{fee_denom} - $q->{fee_num}) * 10000 / $q->{fee_denom})),
    );
    push @rows, kv_row('Execution fee', "\x{2248} " . fmt_amount($ex_fee->bstr, 9, 4) . ' ERG (max '
                                        . fmt_amount($order->{max_ex_fee}, 9) . ')') if $order;
    push @rows,
        kv_row('Network fee', fmt_amount($fee, 9) . ' ERG'),
        kv_row('Minimum received', fmt_amount($show_min, $to->{decimals}) . " $to->{ticker}");
    push @rows, child(label('A bot completes the order at the pool price at that moment, usually within a '
                            . 'few minutes, and never below the minimum. '
                            . ($s->{to} eq ERG ? 'The execution fee is taken from the ERG you receive. '
                                               : 'The execution fee is paid in ERG on top; the unused part comes back. ')
                            . 'Until it is executed you can cancel it under "My open orders".',
                            'BODY2', color => 'SECONDARY'), align => 'START') if $order;
    push @rows, child(label('Priced on top of ' . ($q->{pending} == 1 ? '1 swap' : "$q->{pending} swaps")
                            . ' already waiting in this pool.', 'BODY2', color => 'SECONDARY'), align => 'START')
        if !$order && ($q->{pending} || 0) > 0;
    return @rows;
}

sub finish_quote {    # balance check, Swap / Place order button, and the response
    my ($q, $s, $from, $to, $pool, $min_out, $fee, $order, $rows, $is_limit, %opt) = @_;
    my @rows = @$rows;
    my @extra;
    my $short = 0;
    if (defined $q->{balance} && !$NO_SHORT) {
        my $need = Math::BigInt->new($s->{amount});
        if ($s->{from} eq ERG) {
            $need->badd($fee + 1000000);                  # network fee + a minimal change box
            $need->badd($order->{extra}) if $order;       # execution fee deposit
        }
        $short = 1 if $need->bcmp(Math::BigInt->new($q->{balance})) > 0;
    }
    if (!$s->{address}) {
        push @rows, label('Choose your wallet address above to swap.', 'BODY1', talign => 'CENTER'),
                    button('Refresh quote', 'preview', style => 'SECONDARY');
    }
    elsif ($short) {
        my $have = fmt_amount($q->{balance}, $from->{decimals}) . " $from->{ticker}";
        push @rows, label($s->{from} eq ERG
                              ? "Not enough ERG: this address holds $have, and the swap also needs the fees."
                              : "Not enough $from->{ticker}: this address holds $have.", 'BODY1', talign => 'CENTER'),
                    button('Refresh quote', 'preview', style => 'SECONDARY');
    }
    else {
        my $url = 'ergopay://' . ergopay_host() . '/api.pl?action=ergopay'
                . "&p=$pool->{id}&f=$s->{from}&a=$s->{amount}&m=" . $min_out->bstr . "&addr=$s->{address}"
                . ($order ? '&o=1' : '') . ($is_limit ? '&l=1' : '') . ($opt{hop} ? "&h=$opt{hop}" : '');
        # a random id links this quote to the transaction the wallet is about to fetch (see act_status)
        my $nonce = new_nonce();
        if (defined $nonce && record_file($nonce)) {
            $url .= "&n=$nonce";
            watch_add('swap', $nonce);    # so the wallet's notification check can report the outcome
            push @extra, O(type => 'BackendRequestAction', url => "$API?action=status&mode=$MODE_Q&simple=$SIMPLE&n=$nonce",
                           id => 'status', postValues => 'NONE');
        }
        push @extra, O(type => 'ErgoPayAction', url => $url, id => 'pay',
                       onFinished => (defined $nonce && record_file($nonce)) ? 'status' : 'refresh');
        push @rows, button($order ? 'Place order' : "Swap $from->{ticker} for $to->{ticker}", 'pay');
        if (my $alt = $opt{alt}) {    # a second way to do the same thing, with its own signing link and status
            my $url2 = 'ergopay://' . ergopay_host() . '/api.pl?action=ergopay'
                     . "&p=$pool->{id}&f=$s->{from}&a=$s->{amount}&m=$alt->{min}&addr=$s->{address}&t=$alt->{next}";
            my $n2 = new_nonce();
            my $ok = defined $n2 && record_file($n2);
            if ($ok) {
                $url2 .= "&n=$n2";
                watch_add('swap', $n2);
                push @extra, O(type => 'BackendRequestAction', url => "$API?action=status&mode=$MODE_Q&simple=$SIMPLE&n=$n2",
                               id => 'status2', postValues => 'NONE');
            }
            push @extra, O(type => 'ErgoPayAction', url => $url2, id => 'pay2', onFinished => $ok ? 'status2' : 'refresh');
            push @rows, O(type => 'HorizontalRule', vPadding => 'HALF_DEFAULT'),
                        child(label($alt->{note}, 'BODY2', color => 'SECONDARY'), align => 'START'),
                        button($alt->{button}, 'pay2', style => 'SECONDARY');
        }
        push @rows, button('Refresh quote', 'preview', style => 'TEXT');
    }

    my $box = O(type => 'Box', id => 'quote',
                children => [ child(card(column(\@rows, padding => 'DEFAULT', spacing => 'HALF_DEFAULT')), hAlign => 'JUSTIFY') ]);
    if ($CAPTURE) { @$CAPTURE = ($box, @extra); return }
    mosaik_replace($box, @extra);
}

# ---- open orders: found on-chain by the address's key, nothing is stored here

sub ergopay_host { my $h = $BASE; $h =~ s{^https?://}{}; return $h }

sub describe_amount {    # "5 ERG" for known tokens, a short id for unknown ones
    my ($reg, $id, $raw) = @_;
    my $t = $reg->{tokens}{$id};
    return $t ? fmt_amount($raw, $t->{decimals}) . " $t->{ticker}"
              : "$raw units of token " . substr($id, 0, 6) . "\x{2026}";
}

sub act_orders {
    my $reg = registry();
    my $s   = clean_state(posted_values(), $reg);
    return mosaik_dialog('Choose your wallet address first.') unless $s->{address};
    my $r = chain('orders', { address => $s->{address} });
    return mosaik_dialog($r->{error} || 'Could not load your orders. Please try again.') unless $r->{ok};

    my (@rows, @extra);
    push @rows, child(label('Open orders', 'BODY1BOLD'), align => 'START');
    my $n = 0;
    for my $o (@{ $r->{orders} || [] }) {
        next unless ($o->{box_id} // '') =~ /^[0-9a-f]{64}\z/ && ($o->{amount} // '') =~ /^\d+\z/
                 && ($o->{min_out} // '') =~ /^\d+\z/ && ($o->{from} // '') =~ /^[0-9a-f]{64}\z/
                 && ($o->{to} // '') =~ /^[0-9a-f]{64}\z/;
        $n++;
        push @extra, O(type => 'ErgoPayAction', id => "refund$n", onFinished => 'orders',
                       url => 'ergopay://' . ergopay_host() . "/api.pl?action=ergopay&r=$o->{box_id}&addr=$s->{address}");
        push @rows,
            O(type => 'HorizontalRule', vPadding => 'QUARTER_DEFAULT'),
            child(label('Sell ' . describe_amount($reg, $o->{from}, $o->{amount}) . ' for at least '
                        . describe_amount($reg, $o->{to}, $o->{min_out}), 'BODY1'), align => 'START'),
            button('Cancel and refund', "refund$n", style => 'SECONDARY');
    }
    push @rows, child(label('No open orders on this address. Executed and cancelled orders disappear from this list.',
                            'BODY2', color => 'SECONDARY'), align => 'START') unless $n;
    push @rows, child(label('An order that is still here after a few minutes is waiting for the price to come back '
                            . 'above its minimum. You can cancel it at any time.', 'BODY2', color => 'SECONDARY'),
                      align => 'START') if $n;
    push @rows, button('Refresh', 'orders', style => 'TEXT');
    mosaik_replace(O(type => 'Box', id => 'orders',
                     children => [ child(card(column(\@rows, padding => 'DEFAULT', spacing => 'HALF_DEFAULT')), hAlign => 'JUSTIFY') ]),
                   @extra);
}

# ---- ErgoPay: the wallet fetches the transaction here, at the moment of signing,
# so it is always built against the pool's latest state.

sub ergopay_error { out_json(O(message => $_[0], messageSeverity => 'ERROR')) }

sub act_ergopay {
    my %p = map { $_ => scalar $cgi->param($_) } qw(p f a m addr o r n l h t);
    return ergopay_refund(\%p) if defined $p{r};
    my $order = (defined $p{o} && $p{o} eq '1') ? 1 : 0;
    for my $k (qw(p f)) {
        return ergopay_error('Invalid swap request.') unless defined $p{$k} && $p{$k} =~ /^[0-9a-f]{64}\z/;
    }
    for my $k (qw(a m)) {
        return ergopay_error('Invalid swap request.') unless defined $p{$k} && $p{$k} =~ /^[1-9]\d{0,18}\z/;
    }
    return ergopay_error('Invalid swap request.')
        unless defined $p{addr} && $p{addr} =~ /^[1-9A-HJ-NP-Za-km-z]{40,60}\z/;

    # only pools from the published list, and only the pair that pool really trades
    my $reg = registry();
    my ($pool) = grep { $_->{id} eq $p{p} } map { values %$_ } values %{ $reg->{pair} };
    return ergopay_error('This pool is not available for swaps.')
        unless $pool && ($pool->{x}{id} eq $p{f} || $pool->{y}{id} eq $p{f});

    # a route through ERG: both pools from the published list, first one trades the token for ERG
    my $hop;
    if (defined $p{h}) {
        ($hop) = grep { $_->{id} eq $p{h} } values %{ $reg->{pair}{ +ERG } || {} };
        return ergopay_error('This route is not available.')
            unless $hop && !$order && $p{h} =~ /^[0-9a-f]{64}\z/ && $p{h} ne $p{p} && $p{f} ne ERG && $pool->{x}{id} eq ERG;
        $order = 1;    # from here on it is tracked like an order: there is an order box to watch
    }
    my $r = chain('build', { pool => $p{p}, from => $p{f}, amount => $p{a}, min_out => $p{m}, address => $p{addr},
                             ($hop ? (hop_pool => $hop->{id}) : ()),
                             mode => $hop ? 'hop' : $order ? 'order' : 'direct',
                             limit => ($order && defined $p{l} && $p{l} eq '1') ? JSON::PP::true : JSON::PP::false });
    return ergopay_error($r->{error} || 'The swap could not be prepared. Please try again.') unless $r->{ok};

    my ($from, $to) = @{ $reg->{tokens} }{ $r->{from}, $r->{to} };
    return ergopay_error('The swap could not be prepared. Please try again.') unless $from && $to;
    warn "sigmaswap: built " . ($order ? 'order' : 'swap') . " tx $r->{tx_id} pool " . substr($p{p}, 0, 8) . "\n";    # audit trail, public data only
    save_record($p{n}, {
        app => 'swap', t => time, mode => ($order ? 'order' : 'direct'), tx_id => $r->{tx_id}, watch_box => $r->{watch_box},
        order_box => $r->{order_box}, address => $r->{address}, from => $r->{from}, to => $r->{to},
        amount => $r->{amount}, out => $r->{out}, min_out => $r->{min_out}, limit => ($r->{limit} ? 1 : 0),
        ($hop ? (hop => 1) : ()),
        # first of two direct swaps the user signs one after the other: where the ERG goes next
        ((!$order && $r->{to} eq ERG && defined $p{t} && $p{t} =~ /^[0-9a-f]{64}\z/ && $p{t} ne $r->{from} && $reg->{pair}{ +ERG }{ $p{t} })
            ? (next => $p{t}) : ()),
    }) if defined $p{n} && $p{n} =~ /^[0-9a-f]{32}\z/ && note_is_ours($p{n}, 'swap');
    order_register($r->{order_box}, $r->{address}) if $order;    # the completing bot watches it from now on
    # The signing message is the last thing the user reads, and it may be reached through a
    # link they did not build themselves. So: token names in their unambiguous form (the id
    # is added when two listed tokens share a name), the minimum always stated, and a loud
    # warning when the trade moves the price a lot.
    my $pays = fmt_amount($r->{amount}, $from->{decimals}) . " $from->{label}";
    my $gets = fmt_amount($r->{out}, $to->{decimals}) . " $to->{label}";
    my $net  = 'Network fee ' . fmt_amount($r->{miner_fee}, 9) . ' ERG.';
    my ($msg, $severity);
    if ($hop) {
        my $least  = fmt_amount($r->{min_out}, $to->{decimals}) . " $to->{label}";
        my $impact = ($r->{impact_bps} // 0) + 0;
        $msg = "SigmaSwap: swap $pays for about $gets through ERG, and never less than $least. Your $from->{label} is swapped for "
             . fmt_amount($r->{mid}, 9) . " ERG now; a bot then swaps that ERG for $to->{label} (fee up to "
             . fmt_amount($r->{max_ex_fee}, 9) . " ERG). $net Until the bot is done you can cancel in SigmaSwap and take the ERG.";
        $msg .= ' WARNING: this route moves the pool prices by ' . fmt_pct($impact) . ', so you receive much less than the market rate.'
            if $impact >= 500;
        $severity = $impact >= 500 ? 'WARNING' : 'INFORMATION';
    }
    elsif ($order) {
        my $least = fmt_amount($r->{min_out}, $to->{decimals}) . " $to->{label}";
        $msg = $r->{limit}
            ? "SigmaSwap limit order: sell $pays for at least $least. It waits until the price is reached; "
              . "you can cancel it in SigmaSwap at any time. $net"
            : "SigmaSwap order: sell $pays for about $gets, and never less than $least. A bot completes it; execution fee up to "
              . fmt_amount($r->{max_ex_fee}, 9) . " ERG. $net You can cancel the order in SigmaSwap until it is executed.";
        $severity = 'INFORMATION';
    }
    else {
        my $impact = ($r->{impact_bps} // 0) + 0;
        my $next = (defined $p{t} && $p{t} =~ /^[0-9a-f]{64}\z/ && $p{t} ne $r->{from} && $r->{to} eq ERG && $reg->{pair}{ +ERG }{ $p{t} })
            ? $reg->{tokens}{ $p{t} } : undef;
        $msg = $next ? "SigmaSwap, step 1 of 2: swap $pays for $gets. $net Step 2, ERG for $next->{label}, is a second swap you sign afterwards."
                     : "SigmaSwap: swap $pays for $gets. $net";
        $msg .= ' WARNING: this trade moves the pool price by ' . fmt_pct($impact) . ', so you receive much less than the market rate.'
            if $impact >= 500;
        $severity = $impact >= 500 ? 'WARNING' : 'INFORMATION';
    }
    out_json(O(reducedTx => $r->{reduced_tx}, address => $r->{address}, message => $msg, messageSeverity => $severity));
}

sub ergopay_refund {
    my ($p) = @_;
    return ergopay_error('Invalid request.')
        unless $p->{r} =~ /^[0-9a-f]{64}\z/ && defined $p->{addr} && $p->{addr} =~ /^[1-9A-HJ-NP-Za-km-z]{40,60}\z/;
    my $r = chain('refund', { box => $p->{r}, address => $p->{addr} });
    return ergopay_error($r->{error} || 'The refund could not be prepared. Please try again.') unless $r->{ok};
    my $reg = registry();
    warn "sigmaswap: built refund tx $r->{tx_id}\n";
    out_json(O(
        reducedTx       => $r->{reduced_tx},
        address         => $r->{address},
        message         => 'SigmaSwap: cancel your order and return ' . describe_amount($reg, $r->{from}, $r->{amount})
                           . ' (plus the unused fee deposit) to your address. Network fee '
                           . fmt_amount($r->{miner_fee}, 9) . ' ERG.',
        messageSeverity => 'INFORMATION',
    ));
}

# ---- notifications: the wallet asks now and then whether anything happened

sub act_notify {
    my $reg = registry();
    notify_json(notifications('swap', sub {
        my ($it) = @_;
        my $r = chain('status', { map { $_ => $it->{$_} } qw(tx_id watch_box order_box mode address to) });
        return (0) unless $r->{ok};
        my $st   = $r->{state} // 'unknown';
        my $what = describe_amount($reg, $it->{from}, $it->{amount});
        if ($it->{mode} eq 'order') {
            return (1, "Your swap of $what through ERG is complete: you received "
                       . describe_amount($reg, $it->{to}, $r->{received} // $it->{out}) . '.') if $st eq 'executed' && $it->{hop};
            return (1, "Your order for $what was filled: you received "
                       . describe_amount($reg, $it->{to}, $r->{received} // $it->{out}) . '.') if $st eq 'executed';
            return (1) if $st eq 'cancelled';
            return (1, "Your order for $what was not placed. Nothing was spent.") if $st eq 'failed';
        }
        else {
            return (1, "Your swap of $what is complete: you received " . describe_amount($reg, $it->{to}, $it->{out}) . '.')
                if $st eq 'confirmed';
            return (1, "Your swap of $what did not go through. Nothing was spent.") if $st eq 'failed';
        }
        return (1) if $st eq 'unknown' && time - ($it->{t} || 0) > 86400;    # never signed: forget it
        return (0);
    }));
}

# ---- landing page helpers

sub act_pools {
    my $reg = registry();
    my (%done, @list);
    for my $p (sort { $b->{tvl} <=> $a->{tvl} } map { values %$_ } values %{ $reg->{pair} }) {
        next if $done{ $p->{id} }++;
        push @list, O(x => $reg->{tokens}{ $p->{x}{id} }{label}, y => $reg->{tokens}{ $p->{y}{id} }{label},
                      xi => icon_path($p->{x}{id}), yi => icon_path($p->{y}{id}),
                      tvl => N(sprintf('%.2f', $p->{tvl})));
    }
    success_json(pools => \@list);
}

sub act_health {
    my $r = chain('health', { network => 1 });
    return die_json($r->{error} || 'helper failed') unless $r->{ok};
    # no version numbers here: this endpoint is public
    success_json(helper => 'ok', height => N($r->{height} || 0), pools => N(scalar @{ get_pools() }), base_url => $BASE);
}

// Copyright (c) 2026 Federico Abrignani. All rights reserved.
/// NPLEX Fractional - Fractionalize LTC1 Tokens into real Coins
/// 
/// Allows investors to split their LTC1Token balance into real fungible
/// Coin<F> tokens (DEX-tradeable). The TreasuryCap is locked in a shared
/// FractionalVault so anyone can redeem coins back into LTC1Tokens.

module nplex::fractional;

use nplex::ltc1::{Self, LTC1Token, LTC1Package};
use iota::coin::{Self, Coin, TreasuryCap};
use std::type_name;
use nplex::events;

// ==================== Errors ====================
const E_TREASURY_NOT_FRESH: u64 = 2001;
const E_PACKAGE_MISMATCH: u64 = 2002;
const E_ZERO_AMOUNT: u64 = 2003;

// ==================== Structs ====================

/// Shared vault holding the TreasuryCap for a fractionalized LTC1Token.
/// Anyone can redeem Coin<F> against this vault to get a new LTC1Token.
public struct FractionalVault<phantom F> has key {
    id: UID,
    /// Which LTC1Package the fractionalized token belongs to
    package_id: ID,
    /// The locked TreasuryCap — only this contract can mint/burn
    treasury_cap: TreasuryCap<F>,
    /// Snapshot of claimed_revenue at fractionalization time (for proportional accounting)
    total_claimed_snapshot: u64,
    /// Total balance that was fractionalized (= total coins minted)
    total_fractionalized: u64,
}

// ==================== Entry Functions ====================

/// Fractionalize: convert `amount` of an LTC1Token's balance into real Coin<F>.
/// 
/// Security: asserts TreasuryCap total_supply == 0 (no pre-minting allowed).
/// The TreasuryCap is locked in a shared FractionalVault.
///
/// Caller must own the LTC1Token and pass a fresh TreasuryCap<F>.
#[allow(lint(share_owned))]
public entry fun fractionalize<F>(
    token: &mut LTC1Token,
    treasury_cap: TreasuryCap<F>,
    amount: u64,
    ctx: &mut TxContext
) {
    // 1. Security: no coins must have been minted before
    assert!(coin::total_supply(&treasury_cap) == 0, E_TREASURY_NOT_FRESH);
    assert!(amount > 0, E_ZERO_AMOUNT);

    // 2. Subtract balance from token (handles validation + proportional claimed split)
    let (_balance_removed, claimed_split) = ltc1::subtract_balance(token, amount);

    // 3. Mint coins
    let mut cap = treasury_cap;
    let coins = coin::mint(&mut cap, amount, ctx);

    // 4. Create shared vault with the TreasuryCap locked inside
    let vault = FractionalVault<F> {
        id: object::new(ctx),
        package_id: ltc1::package_id(token),
        treasury_cap: cap,
        total_claimed_snapshot: claimed_split,
        total_fractionalized: amount,
    };

    // 5. Emit Event
    // 5. Emit Event
    events::emit_vault_created(
        object::id(&vault),
        ltc1::package_id(token),
        type_name::get<F>().into_string(),
        amount,
        ctx.sender(),
    );

    // 6. Share the vault so anyone can redeem
    iota::transfer::share_object(vault);

    // 7. Send coins to the caller
    iota::transfer::public_transfer(coins, ctx.sender());
}

/// Redeem: burn Coin<F> and receive a new LTC1Token with the corresponding balance.
/// The new token's claimed_revenue is set proportionally from the vault snapshot,
/// ensuring correct revenue accounting (no double-claims).
///
/// Anyone holding Coin<F> can call this (e.g., DEX buyers).
public entry fun redeem<F, P>(
    vault: &mut FractionalVault<F>,
    coins: Coin<F>,
    package: &LTC1Package<P>,
    ctx: &mut TxContext
) {
    let burn_amount = coin::value(&coins);
    assert!(burn_amount > 0, E_ZERO_AMOUNT);

    // 1. Verify the vault belongs to this package
    assert!(vault.package_id == object::id(package), E_PACKAGE_MISMATCH);

    // 2. Burn the coins
    coin::burn(&mut vault.treasury_cap, coins);

    // 3. Calculate proportional claimed_revenue
    let claimed = if (vault.total_claimed_snapshot == 0) {
        0
    } else {
        (((vault.total_claimed_snapshot as u256) * (burn_amount as u256)) / (vault.total_fractionalized as u256) as u64)
    };

    // 4. Create a new LTC1Token with the redeemed balance
    let token = ltc1::create_token_from_fraction(
        vault.package_id,
        burn_amount,
        claimed,
        ctx
    );

    // 5. Transfer the new token to the caller
    iota::transfer::public_transfer(token, ctx.sender());

    // 6. Check if empty and emit event (but do NOT destroy automatically)
    if (coin::total_supply(&vault.treasury_cap) == 0) {
        events::emit_vault_empty(
            object::id(vault),
            type_name::get<F>().into_string(),
        );
    };
}

/// Merge back: burn Coin<F> and add the balance back to an existing LTC1Token.
/// Useful for the original fractionalizer who still holds their token.
public entry fun merge_back<F>(
    token: &mut LTC1Token,
    vault: &mut FractionalVault<F>,
    coins: Coin<F>,
) {
    let burn_amount = coin::value(&coins);
    assert!(burn_amount > 0, E_ZERO_AMOUNT);

    // 1. Verify same package
    assert!(vault.package_id == ltc1::package_id(token), E_PACKAGE_MISMATCH);

    // 2. Burn the coins
    coin::burn(&mut vault.treasury_cap, coins);

    // 3. Calculate proportional claimed_revenue
    let claimed = if (vault.total_claimed_snapshot == 0) {
        0
    } else {
        (((vault.total_claimed_snapshot as u256) * (burn_amount as u256)) / (vault.total_fractionalized as u256) as u64)
    };

    // 4. Add back to the existing token
    ltc1::add_fraction_balance(token, burn_amount, claimed);

    // 5. Check if empty and emit event
    if (coin::total_supply(&vault.treasury_cap) == 0) {
        events::emit_vault_empty(
            object::id(vault),
            type_name::get<F>().into_string(),
        );
    };
}

/// Manually destroy an empty vault and return the TreasuryCap.
/// Anyone can call this to clean up the state (permissionless).
public entry fun destroy_empty_vault<F>(
    vault: FractionalVault<F>,
    _ctx: &mut TxContext
) {
    assert!(coin::total_supply(&vault.treasury_cap) == 0, E_ZERO_AMOUNT); // Reusing error code for checking non-zero supply

    let FractionalVault {
        id,
        package_id: _,
        treasury_cap,
        total_claimed_snapshot: _,
        total_fractionalized: _,
    } = vault;
    object::delete(id);
    iota::transfer::public_freeze_object(treasury_cap);
}

// ==================== Accessors ====================

public fun vault_package_id<F>(vault: &FractionalVault<F>): ID {
    vault.package_id
}

public fun vault_total_supply<F>(vault: &FractionalVault<F>): u64 {
    coin::total_supply(&vault.treasury_cap)
}

public fun vault_total_fractionalized<F>(vault: &FractionalVault<F>): u64 {
    vault.total_fractionalized
}

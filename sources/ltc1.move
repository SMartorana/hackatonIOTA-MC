// Copyright (c) 2026 Federico Abrignani. All rights reserved.
/// NPLEX LTC1 - Manages the creation of LTC1 contracts
/// 
/// This contract provides the logic for the LTC1 contract.

module nplex::ltc1 {
    use nplex::registry::{Self, NPLEXRegistry};
    use iota::balance::{Self, Balance};
    use iota::coin::{Coin};
    use std::string::{Self, String};
    use iota::display;
    use iota::package;

    // ==================== Errors ====================
    const E_INSUFFICIENT_SUPPLY: u64 = 1001;
    const E_INSUFFICIENT_PAYMENT: u64 = 1002;
    const E_CONTRACT_REVOKED: u64 = 1003;
    const E_WRONG_BOND: u64 = 1004;
    const E_INVALID_SPLIT: u64 = 1005;
    const E_INVALID_TOKEN: u64 = 1006;
    const E_SUPPLY_TOO_LOW: u64 = 1007;

    /// Max investor share in BPS (95%)
    const MAX_INVESTOR_BPS: u64 = 9500;

    /// Min total supply (decrease the dust due to divisions rounding)
    const MIN_SUPPLY: u64 = 1_000_000_000;

    // ==================== Structs ====================

    /// The OTW for package initialization
    public struct LTC1 has drop {}

    /// The LTC1 Witness for Registry Binding
    public struct LTC1Witness has drop {}

    /// The Investor Token
    /// Represents a share of the NPL package and revenue rights.
    public struct LTC1Token has key, store {
        id: UID,
        /// Number of "shares" this token represents
        balance: u64,
        /// Reference to parent LTC1Package
        package_id: ID,
        /// Total IOTA this token has already claimed
        claimed_revenue: u64,
    }

    /// The Owner Bond (Admin Key)
    /// Represents ownership and control over the package.
    public struct OwnerBond has key {
        id: iota::object::UID,
        package_id: iota::object::ID,
        /// Total revenue claimed by the owner so far
        claimed_revenue: u64,
    }

    /// The LTC1 Package (Shared Object)
    /// Contains the state, pools, and metadata visible to everyone.
    public struct LTC1Package<phantom T> has key {
        id: iota::object::UID,
        document_hash: u256,
        
        // Supply & Pricing
        total_supply: u64,
        /// Maximum supply that can be sold to investors
        max_sellable_supply: u64,
        tokens_sold: u64,
        token_price: u64,// in MIST 1,000,000,000 = 1 iota

        // this is metadata, the value the originator of the security gave to this asset at creation
        nominal_value: u64,// in MIST 1,000,000,000 = 1 iota
        
        // Pools
        funding_pool: Balance<T>,
        revenue_pool: Balance<T>,
        total_revenue_deposited: u64,
        /// Revenue earned by unsold tokens (belongs to owner)
        owner_legacy_revenue: u64,
        
        // Metadata & Admin
        owner_bond_id: iota::object::ID,
        creation_timestamp: u64,
        metadata_uri: String,
    }

    // ==================== Initialization ====================

    #[allow(lint(share_owned))]
    fun init(otw: LTC1, ctx: &mut iota::tx_context::TxContext) {
        // 1. Claim Publisher
        let publisher = package::claim(otw, ctx);

        // 2. Define Display for OwnerBond
        let bond_keys = vector[
            string::utf8(b"name"),
            string::utf8(b"description"),
            string::utf8(b"image_url"),
            string::utf8(b"project_url"),
        ];

        let bond_values = vector[
            string::utf8(b"NPLEX Owner Bond"),
            string::utf8(b"Administrative key for LTC1 Package {package_id}"),
            string::utf8(b"https://api.nplex.eu/icons/bond_gold.png"),
            string::utf8(b"https://nplex.eu"),
        ];

        let mut bond_display = display::new_with_fields<OwnerBond>(
            &publisher, bond_keys, bond_values, ctx
        );
        display::update_version(&mut bond_display);

        // 3. Define Display for LTC1Token
        let token_keys = vector[
            string::utf8(b"name"),
            string::utf8(b"description"),
            string::utf8(b"image_url"),
            string::utf8(b"project_url"),
        ];

        let token_values = vector[
            string::utf8(b"NPLEX Investor Token"),
            string::utf8(b"Investor share for LTC1 Package {package_id}"),
            string::utf8(b"https://api.nplex.eu/icons/token_blue.png"),
            string::utf8(b"https://nplex.eu"),
        ];

        let mut token_display = display::new_with_fields<LTC1Token>(
            &publisher, token_keys, token_values, ctx
        );
        display::update_version(&mut token_display);

        // 4. Cleanup & Transfer
        iota::transfer::public_transfer(publisher, iota::tx_context::sender(ctx));
        iota::transfer::public_share_object(bond_display);
        iota::transfer::public_share_object(token_display);
    }

    // ==================== Public Functions ====================

    public entry fun create_contract<T>(
        registry: &mut NPLEXRegistry,
        document_hash: u256,
        total_supply: u64,
        token_price: u64,
        nominal_value: u64,
        investor_split_bps: u64,
        metadata_uri: String,
        ctx: &mut iota::tx_context::TxContext
    ) {
        let owner = iota::tx_context::sender(ctx); // Owner is the creator

        // 0. Validate Split
        assert!(investor_split_bps <= MAX_INVESTOR_BPS, E_INVALID_SPLIT);

        // 1. Validate Total Supply
        assert!(total_supply >= MIN_SUPPLY, E_SUPPLY_TOO_LOW);

        // 2. Claim hash
        let claim = registry::claim_hash(registry, document_hash);

        // 3. Create UIDs first to get IDs (Resolves circular dependency)
        let package_uid = iota::object::new(ctx);
        let bond_uid = iota::object::new(ctx);
        
        let package_id = iota::object::uid_to_inner(&package_uid);
        let bond_id = iota::object::uid_to_inner(&bond_uid);

        // Calculate limits
        let max_sellable_supply = (total_supply * investor_split_bps) / 10000;

        // 4. Create the Package (Shared Object)
        let package = LTC1Package<T> {
            id: package_uid,
            document_hash,
            total_supply,
            max_sellable_supply,
            tokens_sold: 0,
            token_price,
            nominal_value,
            funding_pool: balance::zero<T>(),
            revenue_pool: balance::zero<T>(),
            total_revenue_deposited: 0,
            owner_legacy_revenue: 0,
            owner_bond_id: bond_id,
            creation_timestamp: iota::tx_context::epoch(ctx),
            metadata_uri,
        };

        // 5. Create the Bond (Owned Object - Admin Key)
        let bond = OwnerBond {
            id: bond_uid,
            package_id: package_id,
            claimed_revenue: 0,
        };

        // 6. Bind hash with Witness
        registry::bind_executor(
            registry, 
            claim, 
            package_id, 
            LTC1Witness {}
        );

        // 7. Publish
        // Share the package so ANYONE can find it and interact (buy tokens, view status)
        iota::transfer::share_object(package);
        
        // Send the bond ONLY to the owner (they need this to act as admin)
        iota::transfer::transfer(bond, owner);
    }

    /// Buy tokens from the package
    /// User specifies how many "shares" they want to buy (`amount`)
    /// and provides the Payment in IOTA.
    public entry fun buy_token<T>(
        registry: &NPLEXRegistry,
        package: &mut LTC1Package<T>,
        mut payment: Coin<T>,
        amount: u64,
        ctx: &mut iota::tx_context::TxContext
    ) {
        // 0. Verify Contract Status (not revoked)
        assert!(registry::is_valid_hash(registry, package.document_hash), E_CONTRACT_REVOKED);

        // 1. Check supply
        assert!(amount <= package.max_sellable_supply - package.tokens_sold, E_INSUFFICIENT_SUPPLY);

        // 2. Calculate cost
        let cost = amount * package.token_price;
        assert!(iota::coin::value(&payment) >= cost, E_INSUFFICIENT_PAYMENT);

        // 3. Handle Payment
        let coin_value = iota::coin::value(&payment);
        let paid_balance = if (coin_value == cost) {
            iota::coin::into_balance(payment)
        } else {
            let split = iota::coin::split(&mut payment, cost, ctx);
            iota::transfer::public_transfer(payment, iota::tx_context::sender(ctx)); // Return change
            iota::coin::into_balance(split)
        };
        
        balance::join(&mut package.funding_pool, paid_balance);

        // 4. Calculate Claims
        // When buying new tokens, we must prevent "buying into" past revenue.
        // The revenue attached to these tokens *up to this point* belongs to the Owner (old owner).
        // "Dividend Stripping" protection turned into "Back Pay" for Owner.
        let initial_claimed = (amount * package.total_revenue_deposited) / package.total_supply;

        // 5. Mint Token
        package.tokens_sold = package.tokens_sold + amount;
        
        let token = LTC1Token {
            id: iota::object::new(ctx),
            balance: amount,
            package_id: iota::object::uid_to_inner(&package.id),
            claimed_revenue: initial_claimed,
        };

        // 6. Credit Owner Legacy Revenue
        // The `initial_claimed` amount is money the new buyer IS NOT entitled to.
        // Therefore, it is money the Owner WAS entitled to (as previous owner of unsold stock).
        package.owner_legacy_revenue = package.owner_legacy_revenue + initial_claimed;

        iota::transfer::public_transfer(token, iota::tx_context::sender(ctx));
    }

    /// Deposit revenue into the package (Owner Only)
    /// Requires the OwnerBond (Admin Capability)
    public entry fun deposit_revenue<T>(
        registry: &NPLEXRegistry,
        package: &mut LTC1Package<T>,
        bond: &OwnerBond,
        payment: Coin<T>,
        _ctx: &mut iota::tx_context::TxContext
    ) {
        // 0. Verify Contract Status (not revoked)
        assert!(registry::is_valid_hash(registry, package.document_hash), E_CONTRACT_REVOKED);

        // 1. Verify OwnerBond matches this package
        assert!(bond.package_id == iota::object::uid_to_inner(&package.id), E_WRONG_BOND);

        // 2. Update Metadata
        let amount = iota::coin::value(&payment);
        package.total_revenue_deposited = package.total_revenue_deposited + amount;

        // 3. Deposit to Revenue Pool
        balance::join(&mut package.revenue_pool, iota::coin::into_balance(payment));
    }

    /// Claim Revenue for Owner
    /// Owner is entitled to:
    /// 1. The revenue share of the currently UNSOLD tokens.
    /// 2. The "Legacy Revenue" accumulated from tokens they owned in the past but then sold.
    public entry fun claim_revenue_owner<T>(
        registry: &NPLEXRegistry,
        package: &mut LTC1Package<T>,
        bond: &mut OwnerBond,
        ctx: &mut iota::tx_context::TxContext
    ) {
        // Verify Contract Status (not revoked)
        assert!(registry::is_valid_hash(registry, package.document_hash), E_CONTRACT_REVOKED);

        // 1. Verify Bond
        assert!(bond.package_id == iota::object::uid_to_inner(&package.id), E_WRONG_BOND);

        // 2. Calculate Current Entitlement (Unsold Tokens)
        let unsold_supply = package.total_supply - package.tokens_sold;
        let current_share = (unsold_supply * package.total_revenue_deposited) / package.total_supply;

        // 3. Calculate Total Entitlement (Current + Legacy)
        let total_entitled = current_share + package.owner_legacy_revenue;

        // 4. Calculate Due
        let due = total_entitled - bond.claimed_revenue;
        // In the rare case due is 0 (double claim), we just return.
        if (due == 0) {
            return
        };

        // 5. Update Bond State
        bond.claimed_revenue = bond.claimed_revenue + due;

        // 6. Payout
        let payment = iota::coin::take(&mut package.revenue_pool, due, ctx);
        iota::transfer::public_transfer(payment, iota::tx_context::sender(ctx));
    }

    /// Transfer Owner Bond to a new owner
    /// Requires prior authorization from NPLEX via Registry
    public entry fun transfer_bond(
        registry: &mut NPLEXRegistry,
        bond: OwnerBond,
        new_owner: address,
        _ctx: &mut iota::tx_context::TxContext
    ) {
        // 1. Validate and Consume Ticket from Registry
        // This will abort if:
        // - LTC1 is not an allowed executor (Unlikely if code is published)
        // - Transfer is not authorized
        // - New owner does not match
        registry::consume_transfer_ticket(registry, bond.package_id, new_owner, LTC1Witness {});

        // 2. Transfer Bond
        iota::transfer::transfer(bond, new_owner);
    }

    /// Claim Revenue for Investors
    /// Investors can claim their share of the revenue based on their token balance.
    /// Allowed even if the contract is revoked (so investors can exit).
    public entry fun claim_revenue<T>(
        registry: &NPLEXRegistry,
        package: &mut LTC1Package<T>,
        token: &mut LTC1Token,
        ctx: &mut iota::tx_context::TxContext
    ) {
        // Verify Contract Status (not revoked)
        assert!(registry::is_valid_hash(registry, package.document_hash), E_CONTRACT_REVOKED);

        // 1. Verify Token belongs to this package
        assert!(token.package_id == iota::object::uid_to_inner(&package.id), E_INVALID_TOKEN);

        // 2. Calculate Entitlement
        // Formula: (balance * total_revenue_deposited) / total_supply
        let total_entitled = (token.balance * package.total_revenue_deposited) / package.total_supply;

        // 3. Calculate Due
        let due = total_entitled - token.claimed_revenue;
        if (due == 0) {
            return
        };

        // 4. Update Token
        token.claimed_revenue = token.claimed_revenue + due;

        // 5. Payout
        let payment = iota::coin::take(&mut package.revenue_pool, due, ctx);
        iota::transfer::public_transfer(payment, iota::tx_context::sender(ctx));
    }

    // ==================== Accessors ====================

    public fun balance(token: &LTC1Token): u64 {
        token.balance
    }

    public fun claimed_revenue(token: &LTC1Token): u64 {
        token.claimed_revenue
    }

    /// Verify if a proposed document hash matches the package's registered hash
    public fun verify_document<T>(package: &LTC1Package<T>, document_hash: u256): bool {
        package.document_hash == document_hash
    }
}

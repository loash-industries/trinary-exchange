/// Quote fee-reserve bookkeeping shared by the pool vaults: the deposit
/// descriptor a placement hands to settlement, and the three reserve events.
///
/// The coin `Vault` that used to live here moved to `triex::coin_vault` when the
/// coin pool stack forked; `triex::multicoin_vault` holds the multicoin one. What
/// remains is the part both genuinely share, so a reserve movement looks the same
/// to an indexer whichever pool produced it. Order ids on these events are `u64`:
/// they are emitted for multicoin pools, which use opaque serials. The coin stack
/// emits the `u128`-keyed equivalents from `triex::coin_vault`.
module triex::vault {
    use std::type_name::{Self, TypeName};
    use sui::event;

    // === Structs ===
    /// Metadata describing a quote fee deposit into the reserve bucket.
    /// The taker portion is earned revenue on execution; the maker portion is a
    /// bid maker's fee locked at placement, which stays refundable escrow until
    /// the order fills.
    public struct QuoteFeeDeposit has copy, drop {
        pool_id: ID,
        trading_account_id: ID,
        taker_fee_amount: u64,
        maker_fee_amount: u64,
        timestamp: u64,
    }

    public(package) fun new_quote_fee_deposit(
        pool_id: ID,
        trading_account_id: ID,
        taker_fee_amount: u64,
        maker_fee_amount: u64,
        timestamp: u64,
    ): QuoteFeeDeposit {
        QuoteFeeDeposit {
            pool_id,
            trading_account_id,
            taker_fee_amount,
            maker_fee_amount,
            timestamp,
        }
    }

    public(package) fun quote_fee_deposit_into_parts(
        deposit: QuoteFeeDeposit,
    ): (ID, ID, u64, u64, u64) {
        let QuoteFeeDeposit {
            pool_id,
            trading_account_id,
            taker_fee_amount,
            maker_fee_amount,
            timestamp,
        } = deposit;
        (pool_id, trading_account_id, taker_fee_amount, maker_fee_amount, timestamp)
    }

    public(package) fun emit_pool_fees_deposited<QuoteAsset>(
        pool_id: ID,
        amount: u64,
        trading_account_id: ID,
        timestamp: u64,
    ) {
        event::emit(PoolFeesDeposited {
            pool_id,
            quote_type: type_name::with_defining_ids<QuoteAsset>(),
            amount,
            trading_account_id,
            timestamp,
        });
    }

    #[test_only]
    /// Fields of a `PoolFeesRefunded` for tests asserting that a refund is
    /// attributable to the order and maker it belongs to.
    public fun refunded_event_parts(self: &PoolFeesRefunded): (u128, u64, ID) {
        (self.order_id, self.amount, self.trading_account_id)
    }

    public(package) fun emit_pool_fees_refunded<QuoteAsset>(
        pool_id: ID,
        order_id: u128,
        amount: u64,
        trading_account_id: ID,
        timestamp: u64,
    ) {
        event::emit(PoolFeesRefunded {
            pool_id,
            quote_type: type_name::with_defining_ids<QuoteAsset>(),
            order_id,
            amount,
            trading_account_id,
            timestamp,
        });
    }

    public(package) fun emit_pool_fees_withdrawn<QuoteAsset>(
        pool_id: ID,
        amount: u64,
        timestamp: u64,
    ) {
        event::emit(PoolFeesWithdrawn {
            pool_id,
            quote_type: type_name::with_defining_ids<QuoteAsset>(),
            amount,
            timestamp,
        });
    }

    /// Emitted when quote fees are deposited into pool vault during settlement
    public struct PoolFeesDeposited has copy, drop {
        pool_id: ID,
        quote_type: TypeName,
        amount: u64,
        trading_account_id: ID,
        timestamp: u64,
    }

    /// Emitted when escrowed maker fees leave the reserve back to the maker on a
    /// cancel, modify-down or expiry. Carries the refunded amount only; the
    /// retained share stays in the reserve and is not re-emitted here.
    ///
    /// `order_id` ties this to the `OrderCanceled`, `OrderModified` or
    /// `OrderExpired` emitted for the same release, which carry both halves of the
    /// split. One order can produce several of these across its life: a
    /// modify-down each time it is cut, then a final cancel or expiry.
    public struct PoolFeesRefunded has copy, drop {
        pool_id: ID,
        quote_type: TypeName,
        order_id: u128,
        amount: u64,
        trading_account_id: ID,
        timestamp: u64,
    }

    /// Emitted when admin withdraws accumulated fees from pool vault
    public struct PoolFeesWithdrawn has copy, drop {
        pool_id: ID,
        quote_type: TypeName,
        amount: u64,
        timestamp: u64,
    }
}

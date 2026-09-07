// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// State module represents the current state of the pool. It maintains all
/// the accounts, history, and governance information. It also processes all
/// the transactions and updates the state accordingly.
module triexbook::state;

use sui::table::{Self, Table};
use triexbook::{
    account::{Self, Account},
    balances::{Self, Balances},
    constants,
    fee_schedule::FeeSchedule,
    fill::Fill,
    governance::{Self, Governance},
    history::{Self, History},
    order::Order,
    order_info::OrderInfo
};

// === Errors ===
// const ENoStake: u64 = 1; // #feat:stake - DISABLED
const EMaxOpenOrders: u64 = 2;
// const EAlreadyProposed: u64 = 3; // #feat:gov - DISABLED

// === Structs ===
public struct State has store {
    accounts: Table<ID, Account>,
    history: History,
    governance: Governance, // #feat:gov
}

/// A quote fee taken out of trade proceeds rather than paid in with the order,
/// tagged with the balance manager that was charged. Ask takers and ask makers
/// both pay this way, and one transaction can charge several makers, so the
/// portions stay separate: each reaches the fee reserve attributed to the
/// account that actually paid it.
public struct ProceedsFee has copy, drop, store {
    balance_manager_id: ID,
    amount: u64,
}

public(package) fun balance_manager_id(self: &ProceedsFee): ID {
    self.balance_manager_id
}

public(package) fun amount(self: &ProceedsFee): u64 {
    self.amount
}

/// The quote-fee movements a placement produces, which the pool applies to
/// the vault after settlement.
public struct FeeFlows has copy, drop, store {
    /// Fees charged out of trade proceeds, one entry per account charged.
    proceeds: vector<ProceedsFee>,
    /// Bid-maker escrow that fills in this transaction turned into earned
    /// revenue. The funds are already in the reserve; this reclassifies them
    /// so an admin sweep may take them. Includes the retained share of escrow
    /// released by expiries in the same match.
    recognized: u64,
    /// Escrow refunded to expired bid makers, which the pool must move out of
    /// the reserve so the maker's settled quote is payable. One entry per
    /// expired maker, since a single match can expire several orders belonging
    /// to different accounts.
    refunded: vector<RefundedFee>,
}

/// A refund owed to one expired bid maker. Carries the order it came from so
/// the vault event can be tied back to the `OrderExpired` for that order.
public struct RefundedFee has copy, drop, store {
    order_id: u64,
    balance_manager_id: ID,
    amount: u64,
}

public(package) fun refund_order_id(self: &RefundedFee): u64 {
    self.order_id
}

public(package) fun refund_balance_manager_id(self: &RefundedFee): ID {
    self.balance_manager_id
}

public(package) fun refund_amount(self: &RefundedFee): u64 {
    self.amount
}

public(package) fun proceeds(self: &FeeFlows): &vector<ProceedsFee> {
    &self.proceeds
}

public(package) fun recognized(self: &FeeFlows): u64 {
    self.recognized
}

public(package) fun refunded(self: &FeeFlows): &vector<RefundedFee> {
    &self.refunded
}

/// The escrow a cancel or modify-down releases, split into the part paid back
/// to the maker and the part kept as protocol revenue. The two sum to the
/// released amount, which is what must leave `locked_maker_fees`.
public struct FeeRelease has copy, drop, store {
    refunded: u64,
    retained: u64,
}

public(package) fun release_refunded(self: &FeeRelease): u64 {
    self.refunded
}

public(package) fun release_retained(self: &FeeRelease): u64 {
    self.retained
}

// #feat:stake - DISABLED
// public struct StakeEvent has copy, drop {
//     pool_id: ID,
//     balance_manager_id: ID,
//     epoch: u64,
//     amount: u64,
//     stake: bool,
// }

// #feat:gov - DISABLED
// public struct ProposalEvent has copy, drop {
//     pool_id: ID,
//     balance_manager_id: ID,
//     epoch: u64,
//     // taker_fee: u64,
//     // maker_fee: u64,
//     // stake_required: u64, // #feat:fee_gov
//     fee: u64,
// }

// #feat:gov - DISABLED
// public struct VoteEvent has copy, drop {
//     pool_id: ID,
//     balance_manager_id: ID,
//     epoch: u64,
//     from_proposal_id: Option<ID>,
//     to_proposal_id: ID,
//     stake: u64, // #feat:stake
// }

// #feat:rebate
// public struct RebateEventV2 has copy, drop {
//     pool_id: ID,
//     balance_manager_id: ID,
//     epoch: u64,
//     claim_amount: Balances,
// }

// #feat:rebate
// public struct RebateEvent has copy, drop {
//     pool_id: ID,
//     balance_manager_id: ID,
//     epoch: u64,
//     claim_amount: u64,
// }

public(package) fun empty(ctx: &mut TxContext): State {
    new_state(governance::empty(ctx), ctx)
}

public(package) fun empty_multicoin(ctx: &mut TxContext): State {
    new_state(governance::empty_multicoin(ctx), ctx)
}

fun new_state(governance: Governance, ctx: &mut TxContext): State {
    let trade_params = governance.trade_params();
    let history = history::empty(trade_params, ctx.epoch(), ctx);

    State { history, governance, accounts: table::new(ctx) }
}

/// Up until this point, an OrderInfo object has been created and potentially
/// filled. The OrderInfo object contains all of the necessary information to
/// update the state of the pool. This includes the volumes for the taker and
/// potentially multiple makers.
/// First, fills are iterated and processed, updating the appropriate user's
/// volumes. Funds are settled for those makers. Then, the taker's trading fee
/// is calculated and the taker's volumes are updated. Finally, the taker's
/// balances are settled.
/// Returns the settled and owed balances, plus the quote-fee movements the
/// pool must apply to the vault: fees charged out of proceeds (ask-taker +
/// ask-maker), one entry per account charged, and the bid-maker escrow these
/// fills turned into earned revenue.
/// Resolve the taker and maker rates this account trades at, from its trailing
/// fee turnover against the pool's current tier ladder.
///
/// Called before the order is built, because the maker rate is snapshotted onto
/// the order at construction. Rolls governance first so an order placed on an
/// epoch-boundary transaction resolves against the freshly promoted schedule,
/// and rolls the account so the turnover read is not stale. Returns the entry
/// rung for an account that has never traded, which is also what the temporary
/// balance manager behind a manager-less swap gets.
public(package) fun resolve_trade_rates(
    self: &mut State,
    balance_manager_id: ID,
    ctx: &TxContext,
): (u64, u64) {
    self.governance.update(ctx);
    self.update_account(balance_manager_id, ctx);

    let turnover = self.accounts[balance_manager_id].fee_turnover_total();
    let (_tier, taker_fee, maker_fee) = self.governance.fee_schedule().resolve(turnover);

    (taker_fee, maker_fee)
}

/// The tier index an account currently occupies, for events and views.
///
/// Resolves against turnover as of the current epoch rather than as of the
/// account's last touch, so a dormant account is not reported holding a tier
/// that has already aged out from under it.
public(package) fun account_fee_tier(self: &State, balance_manager_id: ID, ctx: &TxContext): u64 {
    let turnover = self.account_fee_turnover(balance_manager_id, ctx);
    let (tier, _taker_fee, _maker_fee) = self.governance.fee_schedule().resolve(turnover);

    tier
}

/// Fees an account has paid across the trailing window, as of the current
/// epoch. An account that has never traded has none.
public(package) fun account_fee_turnover(
    self: &State,
    balance_manager_id: ID,
    ctx: &TxContext,
): u128 {
    if (!self.accounts.contains(balance_manager_id)) return 0;

    self.accounts[balance_manager_id].fee_turnover_total_at(ctx.epoch())
}

public(package) fun process_create(
    self: &mut State,
    order_info: &mut OrderInfo,
    // ewma_state: &EWMAState, // #feat:ewma
    taker_fee: u64,
    maker_fee: u64,
    pool_id: ID,
    ctx: &TxContext,
): (Balances, Balances, FeeFlows) {
    self.governance.update(ctx);
    self.history.update(self.governance.trade_params(), pool_id, ctx);
    let fills = order_info.fills_ref();
    let mut fee_flows = self.process_fills(fills, ctx);

    self.update_account(order_info.balance_manager_id(), ctx);
    let account = &mut self.accounts[order_info.balance_manager_id()];
    // let account_volume = account.total_volume();
    // let account_stake = account.active_stake();

    // avg exucuted price for taker
    // let avg_executed_price = if (order_info.executed_quantity() > 0) {
    //     math::div(
    //         order_info.cumulative_quote_quantity(),
    //         order_info.executed_quantity(),
    //     )
    // } else {
    //     0
    // };
    //
    // let account_volume_in_cred = order_info
    //     .order_cred_price()
    //     .cred_quantity_u128(
    //         account_volume,
    //         math::mul_u128(account_volume, avg_executed_price as u128),
    //     );

    // Rates arrive already resolved against this account's tier, from
    // `resolve_trade_rates`. The maker rate is the one snapshotted onto the
    // order, so passing it in rather than re-reading governance is what keeps
    // the escrow charged here and the rate recorded on the order identical.
    // let taker_fee = ewma_state.apply_taker_penalty(taker_fee, ctx); // #feat:ewma

    if (order_info.order_inserted()) {
        assert!(account.open_orders().length() < constants::max_open_orders(), EMaxOpenOrders);
        account.add_order(order_info.order_id());
    };
    account.add_taker_volume(order_info.executed_quantity());

    let (mut settled, mut owed) = order_info.calculate_partial_fill_balances(
        taker_fee,
        maker_fee,
    );
    // The taker fee is revenue the moment it is charged, so it counts toward
    // this account's tier. Maker fees are credited in `process_fills`, at fill
    // rather than at placement — escrow a bid maker can still cancel out of
    // must not buy tier progress.
    account.record_fee_turnover(order_info.paid_fees());
    let (old_settled, old_owed) = account.settle();
    self.history.add_total_fees_collected(order_info.paid_fees_balances());
    settled.add_balances(old_settled);
    owed.add_balances(old_owed);

    // Ask-taker fees were deducted from settled proceeds rather than paid in;
    // together with the ask-maker fill deductions collected above they must be
    // moved into the vault's fee reserve by the caller.
    if (!order_info.is_bid() && order_info.paid_fees() > 0) {
        fee_flows.proceeds.push_back(ProceedsFee {
            balance_manager_id: order_info.balance_manager_id(),
            amount: order_info.paid_fees(),
        });
    };

    (settled, owed, fee_flows)
}

public(package) fun withdraw_settled_amounts(
    self: &mut State,
    balance_manager_id: ID,
): (Balances, Balances) {
    if (self.accounts.contains(balance_manager_id)) {
        let account = &mut self.accounts[balance_manager_id];

        account.settle()
    } else {
        (balances::empty(), balances::empty())
    }
}

/// Update account settled balances and volumes.
/// Remove order from account orders.
/// The settled balances already include the refundable share of the escrow
/// this cancellation releases; the returned `FeeRelease` tells the pool how
/// much to unlock from the reserve to back it, and how much to keep.
public(package) fun process_cancel(
    self: &mut State,
    order: &mut Order,
    balance_manager_id: ID,
    pool_id: ID,
    price_scaling: u64,
    ctx: &TxContext,
): (Balances, Balances, FeeRelease) {
    self.governance.update(ctx);
    self.history.update(self.governance.trade_params(), pool_id, ctx);
    self.update_account(balance_manager_id, ctx);
    order.set_canceled();

    let balances = order.calculate_cancel_refund(
        order.maker_fee_rate(),
        option::none(),
        price_scaling,
    );
    let (refunded, retained) = order.released_fee_split(
        order.maker_fee_rate(),
        option::none(),
        price_scaling,
    );

    let account = &mut self.accounts[balance_manager_id];
    account.remove_order(order.order_id());
    account.add_settled_balances(balances);

    let (settled, owed) = account.settle();
    self.recognize_retention(retained);

    (settled, owed, FeeRelease { refunded, retained })
}

/// Given the modified quantity, update account settled balances and volumes.
/// The reduction releases escrow on the same terms as `process_cancel`, so a
/// modify-to-minimum-then-cancel cannot dodge the retention.
public(package) fun process_modify(
    self: &mut State,
    balance_manager_id: ID,
    cancel_quantity: u64,
    order: &Order,
    pool_id: ID,
    price_scaling: u64,
    ctx: &TxContext,
): (Balances, Balances, FeeRelease) {
    self.governance.update(ctx);
    self.history.update(self.governance.trade_params(), pool_id, ctx);
    self.update_account(balance_manager_id, ctx);

    let balances = order.calculate_cancel_refund(
        order.maker_fee_rate(),
        option::some(cancel_quantity),
        price_scaling,
    );
    let (refunded, retained) = order.released_fee_split(
        order.maker_fee_rate(),
        option::some(cancel_quantity),
        price_scaling,
    );

    self.accounts[balance_manager_id].add_settled_balances(balances);

    let (settled, owed) = self.accounts[balance_manager_id].settle();
    self.recognize_retention(retained);

    (settled, owed, FeeRelease { refunded, retained })
}

// Process stake transaction. Add stake to account and update governance.
// #feat:stake #feat:gov - DISABLED
// public(package) fun process_stake(
//     self: &mut State,
//     pool_id: ID,
//     balance_manager_id: ID,
//     new_stake: u64,
//     ctx: &TxContext,
// ): (Balances, Balances) {
//     self.governance.update(ctx);
//     self.history.update(self.governance.trade_params(), pool_id, ctx);
//     self.update_account(balance_manager_id, ctx);
//
//     let (stake_before, stake_after) = self.accounts[balance_manager_id].add_stake(new_stake);
//     self.governance.adjust_voting_power(stake_before, stake_after);
//     event::emit(StakeEvent {
//         pool_id,
//         balance_manager_id,
//         epoch: ctx.epoch(),
//         amount: new_stake,
//         stake: true,
//     });
//
//     self.accounts[balance_manager_id].settle()
// }

// Process unstake transaction.
// Remove stake from account and update governance.
// #feat:stake #feat:gov - DISABLED
// public(package) fun process_unstake(
//     self: &mut State,
//     pool_id: ID,
//     balance_manager_id: ID,
//     ctx: &TxContext,
// ): (Balances, Balances) {
//     self.governance.update(ctx);
//     self.history.update(self.governance.trade_params(), pool_id, ctx);
//     self.update_account(balance_manager_id, ctx);
//
//     let account = &mut self.accounts[balance_manager_id];
//     let active_stake = account.active_stake();
//     let inactive_stake = account.inactive_stake();
//     let voted_proposal = account.voted_proposal();
//     account.remove_stake();
//     self.governance.adjust_voting_power(active_stake + inactive_stake, 0);
//     self.governance.adjust_vote(voted_proposal, option::none(), active_stake);
//     event::emit(StakeEvent {
//         pool_id,
//         balance_manager_id,
//         epoch: ctx.epoch(),
//         amount: active_stake + inactive_stake,
//         stake: false,
//     });
//
//     account.settle()
// }

// Process proposal transaction. Add proposal to governance and update account.
// #feat:gov #feat:stake - DISABLED
// public(package) fun process_proposal(
//     self: &mut State,
//     pool_id: ID,
//     balance_manager_id: ID,
//     // taker_fee: u64,
//     // maker_fee: u64,
//     // stake_required: u64, // #feat:fee_gov
//     fee: u64,
//     ctx: &TxContext,
// ) {
//     self.governance.update(ctx);
//     self.history.update(self.governance.trade_params(), pool_id, ctx);
//     self.update_account(balance_manager_id, ctx);
//     let account = &mut self.accounts[balance_manager_id];
//     let stake = account.active_stake();
//     let proposal_created = account.created_proposal();
//
//     assert!(stake > 0, ENoStake);
//     assert!(!proposal_created, EAlreadyProposed);
//     account.set_created_proposal(true);
//
//     self
//         .governance
//         .add_proposal(
//             // taker_fee,
//             // maker_fee, // #feat:fee_gov
//             fee,
//             // stake_required, // #feat:fee_gov
//             stake,
//             balance_manager_id,
//         );
//     self.process_vote(pool_id, balance_manager_id, balance_manager_id, ctx);
//
//     event::emit(ProposalEvent {
//         pool_id,
//         balance_manager_id,
//         epoch: ctx.epoch(),
//         // taker_fee,
//         // maker_fee,
//         // stake_required, // #feat:fee_gov
//         fee,
//     });
// }

// Process vote transaction. Update account voted proposal and governance.
// #feat:gov #feat:stake - DISABLED
// public(package) fun process_vote(
//     self: &mut State,
//     pool_id: ID,
//     balance_manager_id: ID,
//     proposal_id: ID,
//     ctx: &TxContext,
// ) {
//     self.governance.update(ctx);
//     self.history.update(self.governance.trade_params(), pool_id, ctx);
//     self.update_account(balance_manager_id, ctx);
//
//     let account = &mut self.accounts[balance_manager_id];
//     assert!(account.active_stake() > 0, ENoStake);
//
//     let prev_proposal = account.set_voted_proposal(option::some(proposal_id));
//     self
//         .governance
//         .adjust_vote(
//             prev_proposal,
//             option::some(proposal_id),
//             account.active_stake(),
//         );
//
//     event::emit(VoteEvent {
//         pool_id,
//         balance_manager_id,
//         epoch: ctx.epoch(),
//         from_proposal_id: prev_proposal,
//         to_proposal_id: proposal_id,
//         stake: account.active_stake(),
//     });
// }

// Process claim rebates transaction.
// Update account rebates and settle balances.
// #feat:rebate - DISABLED
// public(package) fun process_claim_rebates<BaseAsset, QuoteAsset>(
//     self: &mut State,
//     pool_id: ID,
//     balance_manager: &BalanceManager,
//     ctx: &TxContext,
// ): (Balances, Balances) {
//     let balance_manager_id = balance_manager.id();
//     self.governance.update(ctx);
//     self.history.update(self.governance.trade_params(), pool_id, ctx);
//     self.update_account(balance_manager_id, ctx);
//
//     let account = &mut self.accounts[balance_manager_id];
//     let claim_amount = account.claim_rebates();
//     event::emit(RebateEventV2 {
//         pool_id,
//         balance_manager_id,
//         epoch: ctx.epoch(),
//         claim_amount,
//     });
//     balance_manager.emit_balance_event(
//         type_name::with_defining_ids<CRED>(),
//         claim_amount.cred(),
//         true,
//     );
//     balance_manager.emit_balance_event(
//         type_name::with_defining_ids<BaseAsset>(),
//         claim_amount.base(),
//         true,
//     );
//     balance_manager.emit_balance_event(
//         type_name::with_defining_ids<QuoteAsset>(),
//         claim_amount.quote(),
//         true,
//     );
//
//     account.settle()
// }

public(package) fun governance(self: &State): &Governance {
    &self.governance
}

public(package) fun governance_mut(self: &mut State, ctx: &TxContext): &mut Governance {
    self.governance.update(ctx);

    &mut self.governance
}

public(package) fun account_exists(self: &State, balance_manager_id: ID): bool {
    self.accounts.contains(balance_manager_id)
}

public(package) fun account(self: &State, balance_manager_id: ID): &Account {
    &self.accounts[balance_manager_id]
}

public(package) fun history_mut(self: &mut State): &mut History {
    &mut self.history
}

public(package) fun history(self: &State): &History {
    &self.history
}

// === Private Functions ===
/// Process fills for all makers. Update maker accounts and history.
/// Maker fees are charged at the rate snapshotted on the maker's order:
/// bid makers locked theirs in quote at placement (the fill recognizes it),
/// ask makers have theirs deducted from the quote proceeds of the fill.
/// Returns the ask-maker fees deducted from proceeds, one entry per maker
/// charged, which the pool must move from the vault's quote balance into the
/// fee reserve, along with the bid-maker escrow these fills earned out.
fun process_fills(self: &mut State, fills: &mut vector<Fill>, ctx: &TxContext): FeeFlows {
    let mut ask_maker_fees = vector[];
    let mut recognized = 0;
    let mut refunded = vector[];
    let mut expiry_retained = 0;
    let mut total_maker_fees = 0;
    let mut i = 0;
    let num_fills = fills.length();
    while (i < num_fills) {
        let fill = &mut fills[i];
        let maker = fill.balance_manager_id();
        self.update_account(maker, ctx);

        let mut maker_fee_earned = 0;
        if (!fill.expired()) {
            // Settlement derives this same amount from the fill, so recording
            // it here is for the fill event and fee accounting: ask makers
            // settle quote net of it, bid makers settle base untouched (their
            // fee left escrow for the reserve at placement).
            let maker_fee = fill.maker_fee_charged();
            maker_fee_earned = maker_fee;
            fill.set_fill_maker_fee(&balances::new(0, maker_fee, 0));
            if (fill.taker_is_bid()) {
                if (maker_fee > 0) {
                    ask_maker_fees.push_back(ProceedsFee {
                        balance_manager_id: maker,
                        amount: maker_fee,
                    });
                };
            } else {
                // A bid maker paid this at placement; the fill is what turns
                // that escrow into revenue.
                recognized = recognized + maker_fee;
            };
            // Maker fees count as collected at fill time, on both sides.
            total_maker_fees = total_maker_fees + maker_fee;
            // #feat:stake - DISABLED: pass 0 for account stake
            self.history.add_volume(fill.base_quantity(), 0);
        } else if (!fill.taker_is_bid()) {
            // An expired bid maker gets their principal back plus the
            // refundable share of the escrow held against it; the retained
            // share becomes revenue. `get_settled_maker_quantities` already
            // credits the refund below, so all that is left here is telling
            // the pool how much to move out of the reserve to back it.
            let refund = fill.maker_fee_refunded();
            if (refund > 0) {
                refunded.push_back(RefundedFee {
                    order_id: fill.maker_order_id(),
                    balance_manager_id: maker,
                    amount: refund,
                });
            };
            expiry_retained = expiry_retained + fill.maker_fee_retained();
        };

        let account = &mut self.accounts[maker];
        account.process_maker_fill(fill);
        // Credited at fill, never at placement: a bid maker's escrow is
        // refundable until it trades, so counting it earlier would let resting
        // orders buy tier progress and cancel out. Expired fills charge nothing
        // and so credit nothing.
        account.record_fee_turnover(maker_fee_earned);

        i = i + 1;
    };
    if (total_maker_fees > 0) {
        self.history.add_total_fees_collected(balances::new(0, total_maker_fees, 0));
    };
    // Expiry retention is realized revenue like any other fee, but it is not
    // trading volume, so it stays out of `add_volume` above.
    self.recognize_retention(expiry_retained);

    FeeFlows { proceeds: ask_maker_fees, recognized: recognized + expiry_retained, refunded }
}

/// Record escrow the protocol kept on a cancel, modify-down or expiry as
/// collected fees. It is realized revenue the moment the order resolves, so
/// leaving it out would make the epoch fee totals understate what the pool
/// actually earned. Deliberately does not touch volume: retention must not
/// buy fee-tier progress, or cancel churn becomes a cheap way to climb.
fun recognize_retention(self: &mut State, amount: u64) {
    if (amount == 0) return;
    self.history.add_total_fees_collected(balances::new(0, amount, 0));
}

/// If account doesn't exist, create it. Update account volumes and rebates.
fun update_account(self: &mut State, balance_manager_id: ID, ctx: &TxContext) {
    if (!self.accounts.contains(balance_manager_id)) {
        self.accounts.add(balance_manager_id, account::empty(ctx));
    };
    // Age the trailing fee-turnover window before anything reads or writes it.
    // Deliberately not routed through `account.update` below: that path is
    // rebate-shaped and disabled, and tier progression must not wait on it.
    self.accounts[balance_manager_id].roll_fee_turnover(ctx);
    // #feat:rebate
    // let account = &mut self.accounts[balance_manager_id];
    // let (prev_epoch, maker_volume, _active_stake) = account.update(ctx);
    // if (prev_epoch > 0 && maker_volume > 0) {
    //     // #feat:rebate - removed active_stake > 0 requirement
    //     // let rebates = self.history.calculate_rebate_amount(prev_epoch, maker_volume, active_stake); // #feat:fees
    //     let rebates = self.history.calculate_rebate_amount(prev_epoch, maker_volume);
    //     account.add_rebates(rebates);
    // }
}

#[test_only]
/// Fees the pool has recognized as collected this epoch: fill-time taker and
/// maker fees, plus retention kept from cancels, modify-downs and expiries.
public fun total_fees_collected_for_testing(self: &State): Balances {
    self.history.total_fees_collected_for_testing()
}

#[test_only]
/// Resolve the trader's tier rates and process the order, exactly as
/// `pool::place_order_int` does. Tests written before rates became per-account
/// call this so they keep exercising the real resolution path rather than
/// pinning a hardcoded rate that would drift from production.
public fun process_create_for_testing(
    self: &mut State,
    order_info: &mut OrderInfo,
    pool_id: ID,
    ctx: &TxContext,
): (Balances, Balances, FeeFlows) {
    let (taker_fee, maker_fee) = self.resolve_trade_rates(order_info.balance_manager_id(), ctx);

    self.process_create(order_info, taker_fee, maker_fee, pool_id, ctx)
}

/// Admin function to set the fees for the next epoch.
/// Replaces the proposal/voting system with direct admin control.
public(package) fun set_next_epoch_fee(
    self: &mut State,
    taker_fee: u64,
    maker_fee: u64,
    cancel_retention_bps: u64,
) {
    self.governance.set_next_trade_params(taker_fee, maker_fee, cancel_retention_bps);
}

/// Admin function to set the tier ladder for the next epoch.
public(package) fun set_next_fee_schedule(
    self: &mut State,
    schedule: FeeSchedule,
    cancel_retention_bps: u64,
) {
    self.governance.set_next_fee_schedule(schedule, cancel_retention_bps);
}

public(package) fun fee_schedule(self: &State): &FeeSchedule {
    self.governance.fee_schedule()
}

public(package) fun next_fee_schedule(self: &State): &FeeSchedule {
    self.governance.next_fee_schedule()
}

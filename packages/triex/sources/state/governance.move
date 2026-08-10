// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Governance module handles the governance of the `Pool` that it's attached
/// to.
/// Users with non zero stake can create proposals and vote on them. Winning
/// proposals are used to set the trade parameters for the next epoch.
/// #feat:gov #feat:stake
module triexbook::governance;

use sui::event;
use triexbook::trade_params::{Self, TradeParams};

// use triexbook::{constants, math}; // #feat:gov #feat:stake - DISABLED (used for voting power calculations)

// === Errors ===
// const EInvalidMakerFee: u64 = 1;
const EInvalidTakerFee: u64 = 2;
// const EProposalDoesNotExist: u64 = 3; // #feat:gov - DISABLED
// const EMaxProposalsReachedNotEnoughVotes: u64 = 4; // #feat:gov - DISABLED
const EWhitelistedPoolCannotChange: u64 = 5;
// const EInvalidFeeRate: u64 = 6;

// === Constants ===
const FEE_MULTIPLE: u64 = 1000; // 0.01 basis points
// const MIN_TAKER_STABLE: u64 = 10000; // 0.1 basis points
// const MAX_TAKER_STABLE: u64 = 100000; // 1 basis points
// const MIN_MAKER_STABLE: u64 = 0;
// const MAX_MAKER_STABLE: u64 = 50000; // 0.5 basis points
const MIN_TAKER_VOLATILE: u64 = 100000; // 1 basis points
const MAX_TAKER_VOLATILE: u64 = 20000000; // 200 basis points (2%)
// const MIN_MAKER_VOLATILE: u64 = 0;
// const MAX_MAKER_VOLATILE: u64 = 500000; // 5 basis points

const MIN_FEE_RATE_STABLE: u64 = 10000; // 0.1 basis points
const MAX_FEE_RATE_STABLE: u64 = 100000; // 1 basis

// const MAX_PROPOSALS: u64 = 100; // #feat:gov - DISABLED
// const VOTING_POWER_THRESHOLD: u64 = 100_000_000_000; // 100k cred // #feat:stake #feat:gov - DISABLED

// === Structs ===
// `Proposal` struct that holds the parameters of a proposal and its current
// total votes.
// #feat:gov - DISABLED
// public struct Proposal has copy, drop, store {
//     // stake_required: u64,
//     // taker_fee: u64,
//     // maker_fee: u64, // #feat:fee_gov
//     fee: u64,
//     votes: u64,
// }

/// Details of a pool. This is refreshed every epoch by the first
/// `State` action against this pool.
/// Simplified to admin-controlled fee setting (proposal/voting system disabled).
public struct Governance has store {
    /// Tracks refreshes.
    epoch: u64,
    /// If Pool is whitelisted.
    whitelisted: bool,
    /// If Pool is stable or volatile.
    stable: bool,
    // List of proposals for the current epoch. // #feat:gov - DISABLED
    // proposals: VecMap<ID, Proposal>,
    /// Trade parameters for the current epoch.
    trade_params: TradeParams,
    /// Trade parameters for the next epoch.
    next_trade_params: TradeParams,
    // All voting power from the current stakes. // #feat:stake #feat:gov - DISABLED
    // voting_power: u64,
    // Quorum for the current epoch. // #feat:gov - DISABLED
    // quorum: u64,
}

/// Event emitted when trade parameters are updated.
public struct TradeParamsUpdateEvent has copy, drop {
    // taker_fee: u64,
    // maker_fee: u64,
    // stake_required: u64, // #feat:fee_gov
    fee: u64,
}

// === Public-Package Functions ===
// #feat:fees
// public(package) fun empty(whitelisted: bool, stable_pool: bool, ctx: &TxContext): Governance {

// let default_taker = if (whitelisted) {
//     0
// } else if (stable_pool) {
//     MAX_TAKER_STABLE
// } else {
//     MAX_TAKER_VOLATILE
// };
// let default_maker = if (whitelisted) {
//     0
// } else if (stable_pool) {
//     MAX_MAKER_STABLE
// } else {
//     MAX_MAKER_VOLATILE
// };
public(package) fun empty(whitelisted: bool, stable_pool: bool, ctx: &TxContext): Governance {
    // Unified fee model: all pool types use the same fee rate (2%)
    let default_fee = MAX_TAKER_VOLATILE; // 20,000,000 = 2%
    Governance {
        epoch: ctx.epoch(),
        whitelisted,
        stable: stable_pool,
        // proposals: vec_map::empty(), // #feat:gov - DISABLED
        trade_params: trade_params::new(
            // default_taker,
            // default_maker,
            // constants::default_stake_required(), // #feat:fee_gov
            default_fee,
        ),
        next_trade_params: trade_params::new(
            // default_taker,
            // default_maker,
            // constants::default_stake_required(), // #feat:fee_gov
            default_fee,
        ),
        // voting_power: 0, // #feat:stake #feat:gov - DISABLED
        // quorum: 0, // #feat:gov - DISABLED
    }
}

public(package) fun whitelisted(self: &Governance): bool {
    self.whitelisted
}

public(package) fun stable(self: &Governance): bool {
    self.stable
}

#[test_only]
public fun destroy_for_testing(self: Governance) {
    let Governance {
        epoch: _,
        whitelisted: _,
        stable: _,
        trade_params: _,
        next_trade_params: _,
    } = self;
}

// #feat:gov - DISABLED
// public(package) fun quorum(self: &Governance): u64 {
//     self.quorum
// }

/// Update the governance state. This is called at the start of every epoch.
public(package) fun update(self: &mut Governance, ctx: &TxContext) {
    let epoch = ctx.epoch();
    if (self.epoch == epoch) return;

    self.epoch = epoch;
    // self.quorum = math::mul(self.voting_power, constants::half()); // #feat:gov - DISABLED
    // self.proposals = vec_map::empty(); // #feat:gov - DISABLED
    self.trade_params = self.next_trade_params;

    event::emit(TradeParamsUpdateEvent {
        // taker_fee: self.trade_params.taker_fee(),
        // maker_fee: self.trade_params.maker_fee(),
        // stake_required: self.trade_params.stake_required(), // #feat:fee_gov
        fee: self.trade_params.fee(),
    });
}

// Add a new proposal to governance.
// Check if proposer already voted, if so will give error.
// If proposer has not voted, and there are already MAX_PROPOSALS proposals,
// remove the proposal with the lowest votes if it has less votes than the
// voting power.
// Validation of the account adding is done in `State`.
// #feat:gov #feat:stake - DISABLED
// public(package) fun add_proposal(
//     self: &mut Governance,
//     // taker_fee: u64,
//     // maker_fee: u64,
//     // stake_required: u64,// #feat:fee_gov
//     fee: u64,
//     stake_amount: u64,
//     balance_manager_id: ID,
// ) {
//     assert!(!self.whitelisted, EWhitelistedPoolCannotChange);
//     // #feat:fee_gov
//     // assert!(taker_fee % FEE_MULTIPLE == 0, EInvalidTakerFee);
//     // assert!(maker_fee % FEE_MULTIPLE == 0, EInvalidMakerFee);
//     assert!(fee % FEE_MULTIPLE == 0, EInvalidTakerFee);
//
//     // Validate fee ranges based on stable vs volatile pool
//     if (self.stable) {
//         assert!(fee >= MIN_FEE_RATE_STABLE, EInvalidTakerFee);
//         assert!(fee <= MAX_FEE_RATE_STABLE, EInvalidTakerFee);
//     } else {
//         assert!(fee >= MIN_TAKER_VOLATILE, EInvalidTakerFee);
//         assert!(fee <= MAX_TAKER_VOLATILE, EInvalidTakerFee);
//     };
//
//     let voting_power = stake_to_voting_power(stake_amount);
//     if (self.proposals.length() == MAX_PROPOSALS) {
//         self.remove_lowest_proposal(voting_power);
//     };
//     // #feat:fee_gov
//     // let new_proposal = new_proposal(taker_fee, maker_fee, stake_required);
//     let new_proposal = new_proposal(fee);
//     self.proposals.insert(balance_manager_id, new_proposal);
// }

// Vote on a proposal. Validation of the account and stake is done in `State`.
// If `from_proposal_id` is some, the account is removing their vote from that
// proposal.
// If `to_proposal_id` is some, the account is voting for that proposal.
// #feat:gov #feat:stake - DISABLED
// public(package) fun adjust_vote(
//     self: &mut Governance,
//     from_proposal_id: Option<ID>,
//     to_proposal_id: Option<ID>,
//     stake_amount: u64,
// ) {
//     let votes = stake_to_voting_power(stake_amount);
//
//     if (
//         from_proposal_id.is_some() && self
//             .proposals
//             .contains(from_proposal_id.borrow())
//     ) {
//         let proposal = &mut self.proposals[from_proposal_id.borrow()];
//         proposal.votes = proposal.votes - votes;
//         if (proposal.votes + votes > self.quorum && proposal.votes < self.quorum) {
//             self.next_trade_params = self.trade_params;
//         };
//     };
//
//     to_proposal_id.do_ref!(|proposal_id| {
//         assert!(self.proposals.contains(proposal_id), EProposalDoesNotExist);
//
//         let proposal = &mut self.proposals[proposal_id];
//         proposal.votes = proposal.votes + votes;
//         if (proposal.votes > self.quorum) {
//             self.next_trade_params = proposal.to_trade_params();
//         };
//     });
// }

// Adjust the total voting power by adding and removing stake. For example, if
// an account's
// stake goes from 2000 to 3000, then `stake_before` is 2000 and `stake_after`
// is 3000.
// Validation of inputs done in `State`.
// #feat:gov #feat:stake - DISABLED
// public(package) fun adjust_voting_power(
//     self: &mut Governance,
//     stake_before: u64,
//     stake_after: u64,
// ) {
//     self.voting_power =
//         self.voting_power +
//         stake_to_voting_power(stake_after) -
//         stake_to_voting_power(stake_before);
// }

public(package) fun trade_params(self: &Governance): TradeParams {
    self.trade_params
}

public(package) fun next_trade_params(self: &Governance): TradeParams {
    self.next_trade_params
}

/// Admin function to set trade parameters for the next epoch.
/// Replaces the proposal/voting system with direct admin control.
public(package) fun set_next_trade_params(self: &mut Governance, fee: u64) {
    assert!(!self.whitelisted, EWhitelistedPoolCannotChange);
    assert!(fee % FEE_MULTIPLE == 0, EInvalidTakerFee);

    // Validate fee ranges based on stable vs volatile pool
    if (self.stable) {
        assert!(fee >= MIN_FEE_RATE_STABLE, EInvalidTakerFee);
        assert!(fee <= MAX_FEE_RATE_STABLE, EInvalidTakerFee);
    } else {
        assert!(fee >= MIN_TAKER_VOLATILE, EInvalidTakerFee);
        assert!(fee <= MAX_TAKER_VOLATILE, EInvalidTakerFee);
    };

    self.next_trade_params = trade_params::new(fee);
}

// === Private Functions ===
// Convert stake to voting power.
// #feat:stake #feat:gov - DISABLED
// fun stake_to_voting_power(stake: u64): u64 {
//     let mut voting_power = stake.min(VOTING_POWER_THRESHOLD);
//     if (stake > VOTING_POWER_THRESHOLD) {
//         voting_power =
//             voting_power + math::sqrt(stake, constants::cred_unit()) -
//             math::sqrt(VOTING_POWER_THRESHOLD, constants::cred_unit());
//     };
//
//     voting_power
// }

// #feat:fee_gov
// fun new_proposal(taker_fee: u64, maker_fee: u64, stake_required: u64): Proposal {
//     Proposal { taker_fee, maker_fee, stake_required, votes: 0 }
// }
// #feat:gov - DISABLED
// fun new_proposal(fee: u64): Proposal {
//     Proposal { fee, votes: 0 }
// }

// Remove the proposal with the lowest votes if it has less votes than the
// voting power.
// If there are multiple proposals with the same lowest votes, the latest one
// is removed.
// #feat:gov #feat:stake - DISABLED
// fun remove_lowest_proposal(self: &mut Governance, voting_power: u64) {
//     let mut removal_id = option::none();
//     let mut cur_lowest_votes = constants::max_u64();
//     let (keys, values) = self.proposals.into_keys_values();
//
//     self.proposals.length().do!(|i| {
//         let proposal_votes = values[i].votes;
//         if (proposal_votes < voting_power && proposal_votes <= cur_lowest_votes) {
//             removal_id = option::some(keys[i]);
//             cur_lowest_votes = proposal_votes;
//         };
//     });
//
//     assert!(removal_id.is_some(), EMaxProposalsReachedNotEnoughVotes);
//     self.proposals.remove(removal_id.borrow());
// }

// #feat:gov - DISABLED
// fun to_trade_params(proposal: &Proposal): TradeParams {
//     trade_params::new(
//         // proposal.taker_fee,
//         // proposal.maker_fee, // #feat:fee_gov
//         proposal.fee
//     )
// }

// === Test Functions ===
// #feat:gov #feat:stake - DISABLED
// #[test_only]
// public fun voting_power(self: &Governance): u64 {
//     self.voting_power
// }

// #feat:gov - DISABLED
// #[test_only]
// public fun proposals(self: &Governance): VecMap<ID, Proposal> {
//     self.proposals
// }

// #feat:gov - DISABLED
// #[test_only]
// public fun votes(proposal: &Proposal): u64 {
//     proposal.votes
// }

// #feat:gov - DISABLED
// #[test_only]
// public fun params(proposal: &Proposal): (u64) {
//     // (proposal.taker_fee, proposal.maker_fee, proposal.stake_required) // #feat:fee_gov
//     (proposal.fee)
// }

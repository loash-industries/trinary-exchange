// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

// #feat:gov #feat:stake - DISABLED
// All tests in this module are commented out because the proposal/voting
// system has been replaced with admin-controlled fee setting.
// Tests now rely on set_next_trade_params() instead.

/*
#[test_only]
module triexbook::governance_tests;

use std::unit_test::assert_eq;
use sui::{
    address,
    object::id_from_address,
    test_scenario::{next_tx, begin, end},
    unit_test::destroy
};
use triexbook::{constants, governance};

const OWNER: address = @0xF;
const ALICE: address = @0xA;
const BOB: address = @0xB;
const CHARLIE: address = @0xC;
const MAX_PROPOSALS: u256 = 100;

#[test]
fun add_proposal_volatile_ok() {
    let mut test = begin(OWNER);
    let alice = ALICE;

    test.next_tx(alice);
    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());
    // gov.add_proposal(500000, 200000, 10000, 1000, id_from_address(alice)); // #feat:fee_gov
    gov.add_proposal(500000, 1000, id_from_address(alice));
    assert!(gov.proposals().length() == 1, 0);
    // let (taker_fee, maker_fee, stake_required) = gov
    //     .proposals()
    //     .get(&id_from_address(alice))
    //     .params();
    // assert!(taker_fee == 500000, 0);
    // assert!(maker_fee == 200000, 0);
    // assert!(stake_required == 10000, 0); // #feat:fees
    let (fee) = gov.proposals().get(&id_from_address(alice)).params();
    assert!(fee == 500000, 0);

    destroy(gov);
    end(test);
}

#[test, expected_failure(abort_code = governance::EInvalidTakerFee)]
fun add_proposal_volatile_taker_not_multiple_e() {
    let mut test = begin(OWNER);
    let alice = ALICE;

    test.next_tx(alice);
    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());
    // gov.add_proposal(500100, 200000, 10000, 1000, id_from_address(alice)); // #feat:fee_gov
    gov.add_proposal(500100, 1000, id_from_address(alice));
    abort 0
}

#[test, expected_failure(abort_code = governance::EInvalidTakerFee)]
fun add_proposal_volatile_low_taker_e() {
    let mut test = begin(OWNER);
    let alice = ALICE;

    test.next_tx(alice);
    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());
    // gov.add_proposal(99000, 200000, 10000, 1000, id_from_address(alice)); // #feat:fee_gov
    gov.add_proposal(99000, 1000, id_from_address(alice));
    abort 0
}

#[test, expected_failure(abort_code = governance::EInvalidTakerFee)]
fun add_proposal_volatile_high_taker_e() {
    let mut test = begin(OWNER);
    let alice = ALICE;

    test.next_tx(alice);
    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());
    // gov.add_proposal(1010000, 200000, 10000, 1000, id_from_address(alice)); // #feat:fee_gov
    // Test fee above MAX_TAKER_VOLATILE (20M = 2%)
    gov.add_proposal(21000000, 1000, id_from_address(alice));
    abort 0
}

#[test, expected_failure(abort_code = governance::EInvalidTakerFee)]
fun add_proposal_volatile_high_maker_e() {
    let mut test = begin(OWNER);
    let alice = ALICE;

    test.next_tx(alice);
    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());
    // gov.add_proposal(500000, 510000, 10000, 1000, id_from_address(alice)); // #feat:fee_gov
    // Test that fee above max volatile (20M = 2%) fails
    gov.add_proposal(21000000, 1000, id_from_address(alice));
    abort 0
}

#[test]
fun add_proposal_stable_ok() {
    let mut test = begin(OWNER);
    let alice = ALICE;

    test.next_tx(OWNER);
    let whitelisted = false;
    let stable_pool = true;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    test.next_tx(alice);
    // gov.add_proposal(50000, 20000, 10000, 1000, id_from_address(alice)); // #feat:fee_gov
    gov.add_proposal(50000, 1000, id_from_address(alice));
    assert!(gov.proposals().length() == 1, 0);

    destroy(gov);
    end(test);
}

#[test, expected_failure(abort_code = governance::EInvalidTakerFee)]
fun add_proposal_stable_taker_e() {
    let mut test = begin(OWNER);
    let alice = ALICE;

    test.next_tx(OWNER);
    let whitelisted = false;
    let stable_pool = true;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    test.next_tx(alice);
    // gov.add_proposal(500000, 20000, 10000, 1000, id_from_address(alice)); // #feat:fee_gov
    gov.add_proposal(500000, 1000, id_from_address(alice));
    abort 0
}

#[test, expected_failure(abort_code = governance::EInvalidTakerFee)]
fun add_proposal_stable_low_taker_e() {
    let mut test = begin(OWNER);
    let alice = ALICE;

    test.next_tx(OWNER);
    let whitelisted = false;
    let stable_pool = true;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    test.next_tx(alice);
    // gov.add_proposal(9000, 20000, 10000, 10000, id_from_address(alice)); // #feat:fee_gov
    gov.add_proposal(9000, 10000, id_from_address(alice));
    abort 0
}

#[test, expected_failure(abort_code = governance::EInvalidTakerFee)]
fun add_proposal_stable_high_taker_e() {
    let mut test = begin(OWNER);
    let alice = ALICE;

    test.next_tx(OWNER);
    let whitelisted = false;
    let stable_pool = true;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    test.next_tx(alice);
    // gov.add_proposal(110000, 20000, 10000, 10000, id_from_address(alice)); // #feat:fee_gov
    gov.add_proposal(110000, 10000, id_from_address(alice));
    abort 0
}

#[test, expected_failure(abort_code = governance::EInvalidTakerFee)]
fun add_proposal_stable_maker_e() {
    let mut test = begin(OWNER);
    let alice = ALICE;

    test.next_tx(OWNER);
    let whitelisted = false;
    let stable_pool = true;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());
    test.next_tx(alice);
    // gov.add_proposal(50000, 200000, 10000, 1000, id_from_address(alice)); // #feat:fee_gov
    // Test that fee above max stable (100000) fails
    gov.add_proposal(200000, 1000, id_from_address(alice));
    abort 0
}

#[test, expected_failure(abort_code = governance::EWhitelistedPoolCannotChange)]
fun add_proposal_whitelisted_e() {
    let mut test = begin(OWNER);
    let alice = ALICE;

    test.next_tx(OWNER);
    let whitelisted = true;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    test.next_tx(ALICE);
    // gov.add_proposal(500000, 200000, 10000, 1000, id_from_address(alice)); // #feat:fee_gov
    gov.add_proposal(500000, 1000, id_from_address(alice));
    abort 0
}

#[test]
fun adjust_voting_power_ok() {
    let mut test = begin(OWNER);
    let alice = ALICE;
    let mut alice_stake = 0;

    test.next_tx(OWNER);
    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    test.next_tx(alice);
    gov.adjust_voting_power(alice_stake, alice_stake + 1000);
    alice_stake = alice_stake + 1000;
    assert!(gov.voting_power() == 1000, 0);
    gov.adjust_voting_power(alice_stake, alice_stake + 1000);
    alice_stake = alice_stake + 1000;
    assert!(gov.voting_power() == 2000, 0);
    gov.adjust_voting_power(alice_stake, alice_stake + 1000);
    alice_stake = alice_stake + 1000;
    assert!(gov.voting_power() == 3000, 0);
    assert!(gov.quorum() == 0, 0);

    test.next_epoch(OWNER);
    test.next_tx(alice);
    gov.update(test.ctx());
    assert!(gov.quorum() == 1500, 0);

    // alice removes stake by 1000 3 times. reverses the effects.
    gov.adjust_voting_power(alice_stake, alice_stake - 1000);
    alice_stake = alice_stake - 1000;
    assert!(gov.voting_power() == 2000, 0);
    gov.adjust_voting_power(alice_stake, alice_stake - 1000);
    alice_stake = alice_stake - 1000;
    assert!(gov.voting_power() == 1000, 0);
    gov.adjust_voting_power(alice_stake, alice_stake - 1000);
    assert!(gov.voting_power() == 0, 0);

    destroy(gov);
    end(test);
}

#[test]
fun update_ok() {
    let mut test = begin(OWNER);
    let alice = ALICE;

    test.next_tx(OWNER);
    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());
    assert!(gov.voting_power() == 0, 0);
    assert!(gov.quorum() == 0, 0);
    assert!(gov.proposals().length() == 0, 0);
    assert_eq!(gov.trade_params(), gov.next_trade_params());
    gov.adjust_voting_power(0, 1000);
    assert!(gov.voting_power() == 1000, 0);

    test.next_epoch(OWNER);
    test.next_tx(alice);
    gov.update(test.ctx());
    assert!(gov.voting_power() == 1000, 0);
    assert!(gov.quorum() == 500, 0);

    test.next_tx(alice);
    // gov.add_proposal(500000, 200000, 10000, 1000, id_from_address(alice)); // #feat:fee_gov
    gov.add_proposal(500000, 1000, id_from_address(alice));
    gov.adjust_vote(option::none(), option::some(id_from_address(alice)), 1000);
    assert!(gov.proposals().length() == 1, 0);
    assert!(gov.quorum() == 500, 0);
    let trade_params = gov.trade_params();
    // assert!(trade_params.taker_fee() == 1000000, 0);
    // assert!(trade_params.maker_fee() == 500000, 0);
    // assert!(trade_params.stake_required() == constants::default_stake_required(), 0); // #feat:fees
    // Default fee is now 20M (2%) in unified model
    assert!(trade_params.fee() == 20000000, 0);
    let next_trade_params = gov.next_trade_params();
    // assert!(next_trade_params.taker_fee() == 500000, 0);
    // assert!(next_trade_params.maker_fee() == 200000, 0);
    // assert!(next_trade_params.stake_required() == 10000, 0); // #feat:fees
    assert!(next_trade_params.fee() == 500000, 0);

    // update doesn't apply proposal yet since epoch hasn't changed
    gov.update(test.ctx());
    assert_eq!(trade_params, gov.trade_params());
    assert_eq!(next_trade_params, gov.next_trade_params());
    assert!(gov.proposals().length() == 1, 0);
    assert!(gov.voting_power() == 1000, 0);
    assert!(gov.quorum() == 500, 0);

    test.next_epoch(OWNER);
    test.next_tx(alice);
    gov.update(test.ctx());
    let trade_params = gov.trade_params();
    // assert!(trade_params.taker_fee() == 500000, 0);
    // assert!(trade_params.maker_fee() == 200000, 0);
    // assert!(trade_params.stake_required() == 10000, 0); // #feat:fees
    assert!(trade_params.fee() == 500000, 0);
    assert_eq!(trade_params, gov.next_trade_params());
    assert!(gov.proposals().length() == 0, 0);
    assert!(gov.voting_power() == 1000, 0);
    assert!(gov.quorum() == 500, 0);

    destroy(gov);
    end(test);
}

#[test]
fun adjust_vote_ok() {
    let mut test = begin(OWNER);
    let alice = ALICE;
    let bob = BOB;

    test.next_tx(OWNER);
    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());
    gov.adjust_voting_power(0, 500);
    assert!(gov.voting_power() == 500, 0);

    test.next_epoch(OWNER);
    test.next_tx(alice);
    gov.update(test.ctx());
    assert!(gov.quorum() == 250, 0);

    // alice proposes proposal 0, votes with 200 votes, not over quorum
    test.next_tx(alice);
    // gov.add_proposal(500000, 200000, 10000, 200, id_from_address(alice)); // #feat:fee_gov
    gov.add_proposal(500000, 200, id_from_address(alice));
    gov.adjust_vote(option::none(), option::some(id_from_address(alice)), 200);
    assert!(gov.proposals().get(&id_from_address(alice)).votes() == 200, 0);
    // assert!(gov.next_trade_params().taker_fee() == 1000000, 0); // #feat:fees
    // assert!(gov.next_trade_params().maker_fee() == 500000, 0); // #feat:fees
    // assert!(gov.next_trade_params().stake_required() == 10000, 0); // #feat:fees
    // Default fee is now 20M (2%) in unified model
    assert_eq!(gov.next_trade_params().fee(), 20000000);
    assert_eq!(gov.trade_params(), gov.next_trade_params());

    // bob proposes proposal 1, votes with 300 votes, over quorum
    test.next_tx(bob);
    // gov.add_proposal(600000, 300000, 10000, 300, id_from_address(bob)); // #feat:fee_gov
    gov.add_proposal(600000, 300, id_from_address(bob));
    gov.adjust_vote(option::none(), option::some(id_from_address(bob)), 300);
    assert!(gov.proposals().get(&id_from_address(alice)).votes() == 200, 0);
    assert!(gov.proposals().get(&id_from_address(bob)).votes() == 300, 0);
    // assert!(gov.next_trade_params().taker_fee() == 600000, 0);
    // assert!(gov.next_trade_params().maker_fee() == 300000, 0); // #feat:fee_gov
    assert_eq!(gov.next_trade_params().fee(), 600000);

    // alice moves her votes from proposal 0 to 1
    test.next_tx(alice);
    gov.adjust_vote(
        option::some(id_from_address(alice)),
        option::some(id_from_address(bob)),
        200,
    );
    assert!(gov.proposals().get(&id_from_address(alice)).votes() == 0, 0);
    assert!(gov.proposals().get(&id_from_address(bob)).votes() == 500, 0);
    // assert!(gov.next_trade_params().taker_fee() == 600000, 0);
    // assert!(gov.next_trade_params().maker_fee() == 300000, 0); // #feat:fee_gov
    assert_eq!(gov.next_trade_params().fee(), 600000);

    // bob moves his votes from proposal 1 to 0, making it the next trade params
    test.next_tx(bob);
    gov.adjust_vote(
        option::some(id_from_address(bob)),
        option::some(id_from_address(alice)),
        300,
    );
    assert!(gov.proposals().get(&id_from_address(alice)).votes() == 300, 0);
    assert!(gov.proposals().get(&id_from_address(bob)).votes() == 200, 0);
    // assert!(gov.next_trade_params().taker_fee() == 500000, 0);
    // assert!(gov.next_trade_params().maker_fee() == 200000, 0); // #feat:fee_gov
    assert_eq!(gov.next_trade_params().fee(), 500000);

    // bob removes his votes completely, making the default trade params the
    // next trade params
    test.next_tx(bob);
    gov.adjust_vote(option::some(id_from_address(alice)), option::none(), 300);
    assert!(gov.proposals().get(&id_from_address(alice)).votes() == 0, 0);
    assert!(gov.proposals().get(&id_from_address(bob)).votes() == 200, 0);
    // assert!(gov.next_trade_params().taker_fee() == 1000000, 0);
    // assert!(gov.next_trade_params().maker_fee() == 500000, 0); // #feat:fees
    // Default fee is now 20M (2%) in unified model
    assert_eq!(gov.next_trade_params().fee(), 20000000);

    destroy(gov);
    end(test);
}

#[test, expected_failure(abort_code = governance::EProposalDoesNotExist)]
fun adjust_vote_e() {
    let mut test = begin(OWNER);
    let alice = ALICE;

    test.next_tx(alice);
    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());
    gov.adjust_vote(option::none(), option::some(id_from_address(alice)), 1000);
    abort 0
}

#[test, expected_failure(abort_code = governance::EProposalDoesNotExist)]
fun adjust_vote2_e() {
    let mut test = begin(OWNER);
    let alice = ALICE;
    let bob = BOB;

    test.next_tx(alice);
    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());
    // gov.add_proposal(500000, 200000, 10000, 200, id_from_address(alice)); // #feat:fee_gov
    gov.add_proposal(500000, 200000, id_from_address(alice));
    gov.adjust_vote(option::none(), option::some(id_from_address(alice)), 1000);
    gov.adjust_vote(
        option::some(id_from_address(alice)),
        option::some(id_from_address(bob)),
        1000,
    );
    abort 0
}

#[test]
fun adjust_vote_from_removed_proposal_ok() {
    let mut test = begin(OWNER);
    let alice = ALICE;
    let bob = BOB;

    test.next_tx(alice);
    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());
    // gov.add_proposal(500000, 200000, 10000, 200, id_from_address(alice)); // #feat:fee_gov
    gov.add_proposal(500000, 200000, id_from_address(alice));
    gov.adjust_vote(
        option::some(id_from_address(bob)),
        option::some(id_from_address(alice)),
        1000,
    );
    assert!(gov.proposals().get(&id_from_address(alice)).votes() == 1000, 0);

    destroy(gov);
    end(test);
}

#[test, expected_failure(abort_code = governance::EProposalDoesNotExist)]
/// Test two proposals that were added by two different people A and B
/// A with less voting power than B (A had 100000, B had 200000, C had 150000)
/// C votes on A's proposal and pushes it over quorum
/// C then makes a new proposal. The proposal that's removed should be A
/// Check to make sure A's removed by voting on proposal A, which will error
/// (EProposalDoesNotExist)
fun remove_proposal_vote_e() {
    let mut test = begin(OWNER);
    let alice = ALICE;
    let bob = BOB;
    let charlie = CHARLIE;

    test.next_tx(OWNER);
    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());
    gov.adjust_voting_power(0, 450000);

    test.next_epoch(OWNER);
    test.next_tx(alice);
    gov.update(test.ctx());
    assert!(gov.quorum() == 225000, 0);

    let dummy_proposals = MAX_PROPOSALS - 2;

    let mut i = 0;
    while (i < dummy_proposals) {
        let address = address::from_u256(i + (1 << 10));
        // gov.add_proposal(500000, 200000, 10000, 1000, id_from_address(address)); // #feat:fee_gov
        gov.add_proposal(500000, 1000, id_from_address(address));
        // Bigger vote than Alice to make sure proposal doesn't get removed
        gov.adjust_vote(
            option::none(),
            option::some(id_from_address(address)),
            110000,
        );
        i = i + 1;
    };

    // Alice proposes and votes with 100000 stake, not enough to push proposal
    // ALICE over quorum
    // gov.add_proposal(500000, 200000, 10000, 100000, id_from_address(alice)); // #feat:fee_gov
    gov.add_proposal(500000, 100000, id_from_address(alice));
    gov.adjust_vote(
        option::none(),
        option::some(id_from_address(alice)),
        100000,
    );
    assert_eq!(gov.trade_params(), gov.next_trade_params());
    // Bob proposes and votes with 200000 stake, not enough to push proposal Bob
    // over quorum
    // gov.add_proposal(600000, 300000, 20000, 200000, id_from_address(bob)); // #feat:fee_gov
    gov.add_proposal(600000, 200000, id_from_address(bob));
    gov.adjust_vote(option::none(), option::some(id_from_address(bob)), 200000);
    assert_eq!(gov.trade_params(), gov.next_trade_params());

    // Charlie votes with 150000 stake, enough to push proposal ALICE over
    // quorum
    gov.adjust_vote(
        option::none(),
        option::some(id_from_address(alice)),
        150000,
    );
    // assert winning proposal is ALICE
    let trade_params = gov.next_trade_params();
    // assert!(trade_params.taker_fee() == 500000, 0);
    // assert!(trade_params.maker_fee() == 200000, 0);
    // assert!(trade_params.stake_required() == 10000, 0); // #feat:fees
    assert!(trade_params.fee() == 500000, 0);

    assert!(gov.proposals().length() == (100 as u64), 0);

    // Charlie makes a new proposal, proposal ALICE should be removed, not BOB
    gov.adjust_vote(
        option::some(id_from_address(alice)),
        option::none(),
        150000,
    );
    // gov.add_proposal(700000, 400000, 30000, 150000, id_from_address(charlie)); // #feat:fee_gov
    gov.add_proposal(700000, 150000, id_from_address(charlie));
    gov.adjust_vote(
        option::none(),
        option::some(id_from_address(charlie)),
        150000,
    );
    assert!(gov.proposals().contains(&id_from_address(bob)), 0);
    assert!(!gov.proposals().contains(&id_from_address(alice)), 0);

    // Voting on proposal ALICE should error
    gov.adjust_vote(option::none(), option::some(id_from_address(alice)), 100);

    destroy(gov);
    end(test);
}

#[test, expected_failure(abort_code = governance::EMaxProposalsReachedNotEnoughVotes)]
fun remove_proposal_stake_too_low_e() {
    let mut test = begin(OWNER);
    let alice = ALICE;

    test.next_tx(OWNER);
    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    let mut i = 0;
    while (i < MAX_PROPOSALS) {
        let address = address::from_u256(i + (1 << 10));
        // gov.add_proposal(500000, 200000, 10000, 1000, id_from_address(address)); // #feat:fee_gov
        gov.add_proposal(500000, 1000, id_from_address(address));
        // Bigger vote than Alice to make sure proposal doesn't get removed
        gov.adjust_vote(
            option::none(),
            option::some(id_from_address(address)),
            110000,
        );
        i = i + 1;
    };

    assert!(gov.proposals().length() == (MAX_PROPOSALS as u64), 0);
    // gov.add_proposal(500000, 200000, 10000, 1000, id_from_address(alice)); // #feat:fee_gov
    gov.add_proposal(500000, 1000, id_from_address(alice));

    abort 0
}

#[test]
fun adjust_votes_remove_from_removed_ok() {
    let mut test = begin(OWNER);
    let alice = ALICE;
    let bob = BOB;

    test.next_tx(OWNER);
    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());
    // gov.add_proposal(500000, 200000, 10000, 1000, id_from_address(alice)); // #feat:fee_gov
    gov.add_proposal(500000, 200000, id_from_address(alice));
    gov.adjust_vote(option::none(), option::some(id_from_address(alice)), 1000);
    assert!(gov.proposals().get(&id_from_address(alice)).votes() == 1000, 0);

    let mut i = 0;
    while (i < MAX_PROPOSALS - 1) {
        let address = address::from_u256(i + (1 << 10));
        // gov.add_proposal(500000, 200000, 10000, 2000, id_from_address(address)); // #feat:fee_gov
        gov.add_proposal(500000, 2000, id_from_address(address));
        gov.adjust_vote(
            option::none(),
            option::some(id_from_address(address)),
            2000,
        );
        i = i + 1;
    };
    assert!(gov.proposals().length() == 100, 0);

    test.next_tx(bob);
    // gov.add_proposal(500000, 200000, 10000, 3000, id_from_address(bob)); // #feat:fee_gov
    gov.add_proposal(500000, 3000, id_from_address(bob));
    assert!(!gov.proposals().contains(&id_from_address(alice)), 0);
    gov.adjust_vote(
        option::some(id_from_address(alice)),
        option::some(id_from_address(bob)),
        3000,
    );
    assert!(gov.proposals().get(&id_from_address(bob)).votes() == 3000, 0);

    destroy(gov);
    end(test);
}

#[test]
/// Any stake over 100k CRED will be subject to voting power decrease
fun adjust_voting_power_over_threshold_ok() {
    let mut test = begin(OWNER);

    test.next_tx(OWNER);
    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());
    gov.adjust_voting_power(0, 100_000 * constants::cred_unit());
    // Voting power calculation: stake > threshold (100 CRED), so:
    // voting_power = threshold + sqrt(stake) - sqrt(threshold)
    // With stake = 100k CRED, this gives approximately 406227766016
    assert!(gov.voting_power() == 406227766016, 0);
    test.next_epoch(OWNER);
    gov.update(test.ctx());
    // Quorum is half of voting power
    assert!(gov.quorum() == 203113883008, 0);
    gov.adjust_voting_power(
        100_000 * constants::cred_unit(),
        150_000 * constants::cred_unit(),
    );
    test.next_epoch(OWNER);
    gov.update(test.ctx());
    assert!(gov.voting_power() == 477298334620, 0);
    assert!(gov.quorum() == 238649167310, 0);
    gov.adjust_voting_power(
        150_000 * constants::cred_unit(),
        200_000 * constants::cred_unit(),
    );
    test.next_epoch(OWNER);
    gov.update(test.ctx());
    assert!(gov.voting_power() == 537213595499, 0);
    assert!(gov.quorum() == 268606797749, 0);

    destroy(gov);
    end(test);
}
*/

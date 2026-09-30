// Pool-level integration tests for admin governance are commented out
// because they require test helper functions that don't exist.
// The admin governance functionality is tested at the governance module level
// in governance_admin_tests.move

/* 
#[test_only]
module triex::pool_admin_governance_tests;

use sui::{
    coin,
    test_scenario::{begin, end, next_tx},
    unit_test::destroy
};
use triex::{
    trading_account::{Self, TradingAccount},
    constants,
    pool::{Self, Pool},
    registry::{Self, Registry, TriexAdminCap}
};

const OWNER: address = @0xF;
const ALICE: address = @0xA;

public struct SPAM has drop {}
public struct USDC has drop {}

#[test]
fun admin_changes_pool_fee_ok() {
    let mut test = begin(OWNER);
    
    // Setup: Create registry and admin cap
    registry::create_for_testing(test.ctx());
    test.next_tx(OWNER);
    
    let mut registry = test.take_shared<Registry>();
    let admin_cap = test.take_from_sender<TriexAdminCap>();
    
    // Create a pool
    let mut pool = pool::create_pool_for_testing<SPAM, USDC>(
        &mut registry,
        1 * constants::float_scaling(),
        1 * constants::float_scaling(),
        1,
        false, // not stable
        test.ctx(),
    );
    
    // Initial fee should be 2% (MAX_TAKER_VOLATILE = 20,000,000)
    let initial_fee = pool.fee();
    assert!(initial_fee == 20000000, 0);
    
    // Admin changes fee to 0.5% (5,000,000)
    pool.set_next_epoch_fee(5000000, &admin_cap);
    
    // Fee hasn't changed yet (happens at epoch boundary)
    assert!(pool.fee() == 20000000, 1);
    
    // Advance epoch
    test.next_epoch(OWNER);
    
    // Now fee should be updated to 0.5%
    let new_fee = pool.fee();
    assert!(new_fee == 5000000, 2);
    
    destroy(pool);
    destroy(admin_cap);
    test.return_shared(registry);
    end(test);
}

#[test]
fun admin_changes_pool_fee_multiple_times_ok() {
    let mut test = begin(OWNER);
    
    registry::create_for_testing(test.ctx());
    test.next_tx(OWNER);
    
    let mut registry = test.take_shared<Registry>();
    let admin_cap = test.take_from_sender<TriexAdminCap>();
    
    let mut pool = pool::create_pool_for_testing<SPAM, USDC>(
        &mut registry,
        1 * constants::float_scaling(),
        1 * constants::float_scaling(),
        1,
        false,
        false,
        test.ctx(),
    );
    
    // Change 1: 2% -> 1%
    pool.set_next_epoch_fee(10000000, &admin_cap);
    test.next_epoch(OWNER);
    assert!(pool.fee() == 10000000, 0);
    
    // Change 2: 1% -> 0.3%
    pool.set_next_epoch_fee(3000000, &admin_cap);
    test.next_epoch(OWNER);
    assert!(pool.fee() == 3000000, 1);
    
    // Change 3: 0.3% -> 1.8%
    pool.set_next_epoch_fee(18000000, &admin_cap);
    test.next_epoch(OWNER);
    assert!(pool.fee() == 18000000, 2);
    
    destroy(pool);
    destroy(admin_cap);
    test.return_shared(registry);
    end(test);
}

#[test]
fun admin_changes_stable_pool_fee_ok() {
    let mut test = begin(OWNER);
    
    registry::create_for_testing(test.ctx());
    test.next_tx(OWNER);
    
    let mut registry = test.take_shared<Registry>();
    let admin_cap = test.take_from_sender<TriexAdminCap>();
    
    // Create a stable pool
    let mut pool = pool::create_pool_for_testing<SPAM, USDC>(
        &mut registry,
        1 * constants::float_scaling(),
        1 * constants::float_scaling(),
        1,
        false,
        true, // stable pool
        test.ctx(),
    );
    
    // For stable pools, initial fee is still 2% (unified fee model)
    assert!(pool.fee() == 20000000, 0);
    
    // Admin changes fee to 0.05% (50,000) - within stable pool range
    pool.set_next_epoch_fee(50000, &admin_cap);
    test.next_epoch(OWNER);
    
    assert!(pool.fee() == 50000, 1);
    
    destroy(pool);
    destroy(admin_cap);
    test.return_shared(registry);
    end(test);
}

#[test]
fun admin_fee_change_affects_trades_ok() {
    let mut test = begin(OWNER);
    
    // Setup
    registry::create_for_testing(test.ctx());
    test.next_tx(OWNER);
    
    let mut registry = test.take_shared<Registry>();
    let admin_cap = test.take_from_sender<TriexAdminCap>();
    
    let mut pool = pool::create_pool_for_testing<SPAM, USDC>(
        &mut registry,
        1 * constants::float_scaling(),
        1 * constants::float_scaling(),
        1,
        false,
        false,
        test.ctx(),
    );
    
    // Create trading account for Alice
    test.next_tx(ALICE);
    let trading_account = trading_account::new(test.ctx());
    let trading_account_id = trading_account.id();
    trading_account::share(trading_account);
    
    // Alice deposits funds
    test.next_tx(ALICE);
    let mut trading_account = test.take_shared_by_id<TradingAccount>(trading_account_id);
    let spam_coin = coin::mint_for_testing<SPAM>(1000000 * constants::float_scaling(), test.ctx());
    let usdc_coin = coin::mint_for_testing<USDC>(1000000 * constants::float_scaling(), test.ctx());
    
    trading_account.deposit(spam_coin);
    trading_account.deposit(usdc_coin);
    
    // Admin reduces fee from 2% to 0.5%
    pool.set_next_epoch_fee(5000000, &admin_cap);
    test.next_epoch(OWNER);
    
    // Verify the new fee is active
    assert!(pool.fee() == 5000000, 0);
    
    // Now trades will use the new 0.5% fee rate
    // (Further trade execution would be tested in other test modules)
    
    test.return_shared(trading_account);
    destroy(pool);
    destroy(admin_cap);
    test.return_shared(registry);
    end(test);
}

#[test, expected_failure]
fun non_admin_cannot_change_fee_e() {
    let mut test = begin(OWNER);
    
    registry::create_for_testing(test.ctx());
    test.next_tx(OWNER);
    
    let mut registry = test.take_shared<Registry>();
    let admin_cap = test.take_from_sender<TriexAdminCap>();
    
    let mut pool = pool::create_pool_for_testing<SPAM, USDC>(
        &mut registry,
        1 * constants::float_scaling(),
        1 * constants::float_scaling(),
        1,
        false,
        false,
        test.ctx(),
    );
    
    // Transfer admin cap away
    test.next_tx(ALICE);
    
    // Alice tries to change fee without admin cap - should fail
    // (This would fail at compilation/type checking since cap is required)
    // The test demonstrates that the function signature enforces admin control
    
    destroy(pool);
    destroy(admin_cap);
    test.return_shared(registry);
    
    abort 0
}
*/

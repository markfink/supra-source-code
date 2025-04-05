module dexlyn_swap::dao_storage {
    use std::signer;
    use aptos_std::event;

    use supra_framework::coin::{Self, Coin};
    use supra_framework::object;

    use dexlyn_swap::coin_helper;
    use dexlyn_swap::global_config;

    friend dexlyn_swap::liquidity_pool;

    // Error codes.

    /// When storage doesn't exists
    const ERR_NOT_REGISTERED: u64 = 401;

    /// When invalid DAO admin account
    const ERR_NOT_ADMIN_ACCOUNT: u64 = 402;

    /// When LP Object is not created
    const ERR_NOT_LP_OBJECT: u64 = 403;

    /// Wrong order of coin parameters.
    const ERR_WRONG_COIN_ORDER: u64 = 404;

    /// Defined Storage seed that are used for creating object
    const SEED_DAO_STORAGE: vector<u8> = b"dao_storage::Storage";

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    /// Storage for keeping coins
    struct Storage<phantom X, phantom Y, phantom Curve> has key {
        coin_x: Coin<X>,
        coin_y: Coin<Y>
    }

    #[event]
    struct StorageCreatedEvent<phantom X, phantom Y, phantom Curve> has store, drop {}

    #[event]
    struct CoinDepositedEvent<phantom X, phantom Y, phantom Curve> has store, drop {
        x_val: u64,
        y_val: u64,
    }

    #[event]
    struct CoinWithdrawnEvent<phantom X, phantom Y, phantom Curve> has store, drop {
        x_val: u64,
        y_val: u64,
    }

    /// Register storage
    /// Parameters:
    /// * `owner` - owner of storage
    public(friend) fun register<X, Y, Curve>(lp_object_signer: &signer) {
        let object_address = signer::address_of(lp_object_signer);

        assert!(object::is_object(object_address), ERR_NOT_LP_OBJECT);

        move_to(lp_object_signer, Storage<X, Y, Curve> { coin_x: coin::zero<X>(), coin_y: coin::zero<Y>() });

        event::emit(StorageCreatedEvent<X, Y, Curve> {});
    }

    /// Deposit coins to storage from liquidity pool
    /// Parameters:
    /// * `pool_addr` - pool owner address
    /// * `coin_x` - X coin to deposit
    /// * `coin_y` - Y coin to deposit
    public(friend) fun deposit<X, Y, Curve>(
        lp_pool_object_addr: address,
        coin_x: Coin<X>,
        coin_y: Coin<Y>
    ) acquires Storage {
        assert!(object::object_exists<Storage<X, Y, Curve>>(lp_pool_object_addr), ERR_NOT_REGISTERED);

        let x_val = coin::value(&coin_x);
        let y_val = coin::value(&coin_y);
        let storage = borrow_global_mut<Storage<X, Y, Curve>>(lp_pool_object_addr);
        coin::merge(&mut storage.coin_x, coin_x);
        coin::merge(&mut storage.coin_y, coin_y);

        event::emit(CoinDepositedEvent<X, Y, Curve> { x_val, y_val });
    }

    /// Withdraw coins from storage
    /// Parameters:
    /// * `dao_admin_acc` - DAO admin
    /// * `pool_addr` - pool owner address
    /// * `x_val` - amount of X coins to withdraw
    /// * `y_val` - amount of Y coins to withdraw
    /// Returns both withdrawn X and Y coins: `(Coin<X>, Coin<Y>)`.
    public fun withdraw<X, Y, Curve>(
        dao_admin_acc: &signer,
        lp_pool_object_addr: address,
        x_val: u64,
        y_val: u64
    ): (Coin<X>, Coin<Y>)
    acquires Storage {
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_COIN_ORDER);
        assert!(signer::address_of(dao_admin_acc) == global_config::get_dao_admin(), ERR_NOT_ADMIN_ACCOUNT);
        let storage = borrow_global_mut<Storage<X, Y, Curve>>(lp_pool_object_addr);
        let coin_x = coin::extract(&mut storage.coin_x, x_val);
        let coin_y = coin::extract(&mut storage.coin_y, y_val);

        event::emit(CoinWithdrawnEvent<X, Y, Curve> { x_val, y_val });
        (coin_x, coin_y)
    }

    #[view]
    public fun get_accrued_dao_fee<X, Y, Curve>(lp_pool_object_addr: address): (u64, u64) acquires Storage {
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_COIN_ORDER);
        let storage = borrow_global_mut<Storage<X, Y, Curve>>(lp_pool_object_addr);
        (coin::value(&storage.coin_x), coin::value(&storage.coin_y))
    }

    #[test_only]
    public fun get_storage_size<X, Y, Curve>(lp_pool_object_addr: address): (u64, u64) acquires Storage {
        let storage = borrow_global<Storage<X, Y, Curve>>(lp_pool_object_addr);
        let x_val = coin::value(&storage.coin_x);
        let y_val = coin::value(&storage.coin_y);
        (x_val, y_val)
    }

    #[test_only]
    public fun deposit_for_test<X, Y, Curve>(
        pool_addr: address,
        coin_x: Coin<X>,
        coin_y: Coin<Y>
    ) acquires Storage {
        deposit<X, Y, Curve>(pool_addr, coin_x, coin_y);
    }
}

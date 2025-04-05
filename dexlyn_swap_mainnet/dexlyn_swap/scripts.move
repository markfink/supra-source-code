/// The current module contains pre-deplopyed scripts for dexlyn_swap.
module dexlyn_swap::scripts {
    use std::signer;

    use dexlyn_swap_lp::lp_coin::LP;
    use supra_framework::coin;
    use supra_framework::supra_account;

    use dexlyn_swap::dao_storage;
    use dexlyn_swap::liquidity_pool;
    use dexlyn_swap::router;

    /// Register a new liquidity pool for `X`/`Y` pair.
    ///
    /// Note: X, Y generic coin parameters must be sorted.
    public entry fun register_pool<X, Y, Curve>(account: &signer) {
        router::register_pool<X, Y, Curve>(account);
    }

    /// Register a new liquidity pool `X`/`Y` and immediately add liquidity.
    /// * `coin_x_val` - amount of coin `X` to add as liquidity.
    /// * `coin_x_val_min` - minimum amount of coin `X` to add as liquidity (slippage).
    /// * `coin_y_val` - minimum amount of coin `Y` to add as liquidity.
    /// * `coin_y_val_min` - minimum amount of coin `Y` to add as liquidity (slippage).
    ///
    /// Note: X, Y generic coin parameters must be sorted.
    public entry fun register_pool_and_add_liquidity<X, Y, Curve>(
        account: &signer,
        coin_x_val: u64,
        coin_x_val_min: u64,
        coin_y_val: u64,
        coin_y_val_min: u64,
    ) {
        router::register_pool<X, Y, Curve>(account);
        add_liquidity<X, Y, Curve>(
            account,
            coin_x_val,
            coin_x_val_min,
            coin_y_val,
            coin_y_val_min,
        );
    }

    /// Add new liquidity into pool `X`/`Y` and get liquidity coin `LP`.
    /// * `coin_x_val` - amount of coin `X` to add as liquidity.
    /// * `coin_x_val_min` - minimum amount of coin `X` to add as liquidity (slippage).
    /// * `coin_y_val` - minimum amount of coin `Y` to add as liquidity.
    /// * `coin_y_val_min` - minimum amount of coin `Y` to add as liquidity (slippage).
    ///
    /// Note: X, Y generic coin parameters must be sorted.
    public entry fun add_liquidity<X, Y, Curve>(
        account: &signer,
        coin_x_val: u64,
        coin_x_val_min: u64,
        coin_y_val: u64,
        coin_y_val_min: u64,
    ) {
        let coin_x = coin::withdraw<X>(account, coin_x_val);
        let coin_y = coin::withdraw<Y>(account, coin_y_val);

        let account_addr = signer::address_of(account);

        let (coin_x_remainder, coin_y_remainder, lp_coins) =
            router::add_liquidity<X, Y, Curve>(
                coin_x,
                coin_x_val_min,
                coin_y,
                coin_y_val_min,
            );


        supra_account::deposit_coins(account_addr, coin_x_remainder);
        supra_account::deposit_coins(account_addr, coin_y_remainder);
        supra_account::deposit_coins(account_addr, lp_coins);
    }

    /// Remove (burn) liquidity coins `LP` from account, get `X` and`Y` coins back.
    /// * `lp_val` - amount of `LP` coins to burn.
    /// * `min_x_out_val` - minimum amount of X coins to get.
    /// * `min_y_out_val` - minimum amount of Y coins to get.
    ///
    /// Note: X, Y generic coin parameters must be sorted.
    public entry fun remove_liquidity<X, Y, Curve>(
        account: &signer,
        lp_val: u64,
        min_x_out_val: u64,
        min_y_out_val: u64,
    ) {
        let lp_coins = coin::withdraw<LP<X, Y, Curve>>(account, lp_val);

        let account_addr = signer::address_of(account);

        let (coin_x, coin_y) = router::remove_liquidity<X, Y, Curve>(
            lp_coins,
            min_x_out_val,
            min_y_out_val,
        );


        supra_account::deposit_coins(account_addr, coin_x);
        supra_account::deposit_coins(account_addr, coin_y);
    }

    /// Swap exact coin `X` for at least minimum coin `Y`.
    /// * `coin_val` - amount of coins `X` to swap.
    /// * `coin_out_min_val` - minimum expected amount of coins `Y` to get.
    public entry fun swap<X, Y, Curve>(
        account: &signer,
        coin_val: u64,
        coin_out_min_val: u64,
    ) {
        let coin_x = coin::withdraw<X>(account, coin_val);

        let account_addr = signer::address_of(account);

        let coin_y = router::swap_exact_coin_for_coin<X, Y, Curve>(
            coin_x,
            coin_out_min_val,
        );


        supra_account::deposit_coins(account_addr, coin_y);
    }

    /// Swap maximum coin `X` for exact coin `Y`.
    /// * `coin_val_max` - how much of coins `X` can be used to get `Y` coin.
    /// * `coin_out` - how much of coins `Y` should be returned.
    public entry fun swap_into<X, Y, Curve>(
        account: &signer,
        coin_val_max: u64,
        coin_out: u64,
    ) {
        let coin_x = coin::withdraw<X>(account, coin_val_max);

        let account_addr = signer::address_of(account);

        let (coin_x, coin_y) = router::swap_coin_for_exact_coin<X, Y, Curve>(
            coin_x,
            coin_out,
        );


        supra_account::deposit_coins(account_addr, coin_x);
        supra_account::deposit_coins(account_addr, coin_y);
    }

    /// Swap `coin_in` of X for a `coin_out` of Y.
    /// Does not check optimality of the swap, and fails if the `X` to `Y` price ratio cannot be satisfied.
    /// * `coin_in` - how much of coins `X` to swap.
    /// * `coin_out` - how much of coins `Y` should be returned.
    public entry fun swap_unchecked<X, Y, Curve>(
        account: &signer,
        coin_in: u64,
        coin_out: u64,
    ) {
        let coin_x = coin::withdraw<X>(account, coin_in);

        let account_addr = signer::address_of(account);

        let coin_y = router::swap_coin_for_coin_unchecked<X, Y, Curve>(coin_x, coin_out);


        supra_account::deposit_coins(account_addr, coin_y);
    }

    /// To withdraw a part of the accrued DAO fees from the Liquidity Pool Object
    /// Only the Dao Admin can withdraw
    /// `x_val` and `y_val` are the amount of fees for each coin that is going to get withdraw
    public entry fun withdraw_dao_fee<X, Y, Curve>(
        dao_admin: &signer,
        x_val: u64,
        y_val: u64,
    ) {
        let lp_pool_object_addr = liquidity_pool::generate_lp_object_address<X, Y, Curve>();
        let dao_admin_address = signer::address_of(dao_admin);
        let (coin_x, coin_y) = dao_storage::withdraw<X, Y, Curve>(dao_admin, lp_pool_object_addr, x_val, y_val);

        supra_account::deposit_coins<X>(dao_admin_address, coin_x);
        supra_account::deposit_coins<Y>(dao_admin_address, coin_y);
    }


    /// To withdraw a part of the accrued DAO fees from the Liquidity Pool Object
    /// Only the Dao Admin can withdraw entire amount of fees for each coin that is accrueded so far
    public entry fun withdraw_accrued_dao_fee<X, Y, Curve>(
        dao_admin: &signer,
    ) {
        let lp_pool_object_addr = liquidity_pool::generate_lp_object_address<X, Y, Curve>();
        let (max_x_val, max_y_val) = dao_storage::get_accrued_dao_fee<X, Y, Curve>(lp_pool_object_addr);
        let dao_admin_address = signer::address_of(dao_admin);
        let (coin_x, coin_y) = dao_storage::withdraw<X, Y, Curve>(dao_admin, lp_pool_object_addr, max_x_val, max_y_val);

        supra_account::deposit_coins<X>(dao_admin_address, coin_x);
        supra_account::deposit_coins<Y>(dao_admin_address, coin_y);
    }
}

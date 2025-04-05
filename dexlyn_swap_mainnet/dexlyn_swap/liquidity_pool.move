/// dexlyn_swap liquidity pool module.
/// Implements mint/burn liquidity, swap of coins.
module dexlyn_swap::liquidity_pool {
    use std::signer;
    use std::string;
    use std::string::String;
    use aptos_std::event;
    use aptos_std::table;
    use aptos_std::type_info::type_name;

    use dexlyn_swap_lp::lp_coin::LP;
    use supra_framework::account::{Self, SignerCapability};
    use supra_framework::coin::{Self, Coin};
    use supra_framework::object;
    use supra_framework::timestamp;

    use dexlyn_swap::coin_helper;
    use dexlyn_swap::curves;
    use dexlyn_swap::dao_storage;
    use dexlyn_swap::emergency::{Self, assert_no_emergency};
    use dexlyn_swap::global_config;
    use dexlyn_swap::lp_account;
    use dexlyn_swap::math;
    use dexlyn_swap::stable_curve;
    use dexlyn_swap::uq64x64;

    // Error codes.

    /// When coins used to create pair have wrong ordering.
    const ERR_WRONG_PAIR_ORDERING: u64 = 100;

    /// When pair already exists on account.
    const ERR_POOL_EXISTS_FOR_PAIR: u64 = 101;

    /// When not enough liquidity minted.
    const ERR_NOT_ENOUGH_INITIAL_LIQUIDITY: u64 = 102;

    /// When not enough liquidity minted.
    const ERR_NOT_ENOUGH_LIQUIDITY: u64 = 103;

    /// When both X and Y provided for swap are equal zero.
    const ERR_EMPTY_COIN_IN: u64 = 104;

    /// When incorrect INs/OUTs arguments passed during swap and math doesn't work.
    const ERR_INCORRECT_SWAP: u64 = 105;

    /// Incorrect lp coin burn values
    const ERR_INCORRECT_BURN_VALUES: u64 = 106;

    /// When pool doesn't exists for pair.
    const ERR_POOL_DOES_NOT_EXIST: u64 = 107;

    /// Should never occur.
    const ERR_UNREACHABLE: u64 = 108;

    /// When `initialize()` transaction is signed with any account other than @dexlyn_swap.
    const ERR_NOT_ENOUGH_PERMISSIONS_TO_INITIALIZE: u64 = 109;

    /// When pool is locked.
    const ERR_POOL_IS_LOCKED: u64 = 111;

    /// When user is not admin
    const ERR_NOT_ADMIN: u64 = 112;

    // Constants.

    /// Minimal liquidity.
    const MINIMAL_LIQUIDITY: u64 = 1000;

    /// Denominator to handle decimal points for fees.
    const FEE_SCALE: u64 = 10000;

    /// Denominator to handle decimal points for dao fee.
    const DAO_FEE_SCALE: u64 = 100;

    /// Defined Liquidity Pool Admin seed that are used for creating object
    const SEED_LIQUIDITY_POOL_ADMIN: vector<u8> = b"dao_storage::Storage";

    // Public functions.

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    /// Liquidity pool with reserves.
    struct LiquidityPool<phantom X, phantom Y, phantom Curve> has key {
        coin_x_reserve: Coin<X>,
        coin_y_reserve: Coin<Y>,
        last_block_timestamp: u64,
        last_price_x_cumulative: u128,
        last_price_y_cumulative: u128,
        lp_mint_cap: coin::MintCapability<LP<X, Y, Curve>>,
        lp_burn_cap: coin::BurnCapability<LP<X, Y, Curve>>,
        // Scales are pow(10, token_decimals).
        x_scale: u64,
        y_scale: u64,
        locked: bool,
        fee: u64,
        // 1 - 100 (0.01% - 1%)
        dao_fee: u64,
        // 0 - 100 (0% - 100%)
    }

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    /// Stores resource account signer capability under dexlyn_swap account.
    struct PoolAccountCapability has key {
        signer_cap: SignerCapability,
        lp_controller_map: table::Table<address, LPObjectController>
    }

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    struct AdminObjectController has key {
        transfer_ref: object::TransferRef,
        extend_ref: object::ExtendRef,
    }

    struct LPObjectController has store {
        transfer_ref: object::TransferRef,
        extend_ref: object::ExtendRef,
    }

    #[event]
    struct PoolCreatedEvent has drop, store {
        pair_x: String,
        pair_y: String,
        curve: String,
        creator: address,
        pool_address: address,
        timestamp: u64,
    }

    #[event]
    struct LiquidityAddedEvent has drop, store {
        pair_x: String,
        pair_y: String,
        curve: String,
        added_x_val: u64,
        added_y_val: u64,
        lp_tokens_received: u64,
        timestamp: u64,
        reserve_x: u64,
        reserve_y: u64,
    }

    #[event]
    struct LiquidityRemovedEvent has drop, store {
        pair_x: String,
        pair_y: String,
        curve: String,
        returned_x_val: u64,
        returned_y_val: u64,
        lp_tokens_burned: u64,
        timestamp: u64,
        reserve_x: u64,
        reserve_y: u64,
    }

    #[event]
    struct SwapEvent has drop, store {
        pair_x: String,
        pair_y: String,
        curve: String,
        x_in: u64,
        x_out: u64,
        y_in: u64,
        y_out: u64,
        timestamp: u64,
        reserve_x: u64,
        reserve_y: u64,
    }

    #[event]
    struct OracleUpdatedEvent has drop, store {
        pair_x: String,
        pair_y: String,
        curve: String,
        last_price_x_cumulative: u128,
        last_price_y_cumulative: u128,
        timestamp: u64,
    }

    #[event]
    struct UpdateFeeEvent has drop, store {
        pair_x: String,
        pair_y: String,
        curve: String,
        new_fee: u64,
        timestamp: u64,
    }

    #[event]
    struct UpdateDAOFeeEvent has drop, store {
        pair_x: String,
        pair_y: String,
        curve: String,
        new_fee: u64,
        timestamp: u64,
    }

    /// Initializes dexlyn_swap contracts.
    public entry fun initialize(dexlyn_swap_admin: &signer) {
        assert!(signer::address_of(dexlyn_swap_admin) == @dexlyn_swap, ERR_NOT_ENOUGH_PERMISSIONS_TO_INITIALIZE);
        let cons_ref = object::create_named_object(dexlyn_swap_admin, SEED_LIQUIDITY_POOL_ADMIN);
        let object_signer = object::generate_signer(&cons_ref);

        move_to(
            &object_signer,
            AdminObjectController {
                transfer_ref: object::generate_transfer_ref(&cons_ref),
                extend_ref: object::generate_extend_ref(&cons_ref)
            }
        );

        let signer_cap = lp_account::retrieve_signer_cap(dexlyn_swap_admin);
        move_to(&object_signer, PoolAccountCapability { signer_cap, lp_controller_map: table::new() });

        global_config::initialize(dexlyn_swap_admin);
        emergency::initialize(dexlyn_swap_admin);
    }

    #[view]
    public fun get_liquidity_pool_admin_object_address(): address {
        object::create_object_address(&@dexlyn_swap, SEED_LIQUIDITY_POOL_ADMIN)
    }

    #[view]
    public fun generate_lp_object_address<X, Y, Curve>(): address acquires PoolAccountCapability {
        let (lp_name, _lp_symbol) = coin_helper::generate_lp_name_and_symbol<X, Y, Curve>();
        let pool_account = borrow_global<PoolAccountCapability>(get_liquidity_pool_admin_object_address());
        let lp_account_signer = account::create_signer_with_capability(&pool_account.signer_cap);
        let pool_account_address = signer::address_of(&lp_account_signer);
        object::create_object_address(&pool_account_address, *string::bytes(&lp_name))
    }

    fun create_lp_object<X, Y, Curve>(): (signer, signer) acquires PoolAccountCapability {
        let (lp_name, _lp_symbol) = coin_helper::generate_lp_name_and_symbol<X, Y, Curve>();
        let pool_account = borrow_global_mut<PoolAccountCapability>(get_liquidity_pool_admin_object_address());
        let lp_account_signer = account::create_signer_with_capability(&pool_account.signer_cap);
        let cons_ref = object::create_named_object(&lp_account_signer, *string::bytes(&lp_name));
        let object_signer = object::generate_signer(&cons_ref);
        let object_address = object::address_from_constructor_ref(&cons_ref);
        move_to(
            &object_signer,
            AdminObjectController {
                transfer_ref: object::generate_transfer_ref(&cons_ref),
                extend_ref: object::generate_extend_ref(&cons_ref)
            }
        );
        table::add(
            &mut pool_account.lp_controller_map,
            object_address,
            LPObjectController {
                transfer_ref: object::generate_transfer_ref(&cons_ref),
                extend_ref: object::generate_extend_ref(&cons_ref)
            });
        (object_signer, lp_account_signer)
    }

    /// Register liquidity pool `X`/`Y`.
    public fun register<X, Y, Curve>(acc: &signer) acquires PoolAccountCapability {
        assert_no_emergency();

        coin_helper::assert_is_coin<X>();
        coin_helper::assert_is_coin<Y>();
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_PAIR_ORDERING);

        curves::assert_valid_curve<Curve>();

        assert!(
            !object::object_exists<LiquidityPool<X, Y, Curve>>(generate_lp_object_address<X, Y, Curve>()),
            ERR_POOL_EXISTS_FOR_PAIR
        );

        let (lp_object_signer, lp_account_signer) = create_lp_object<X, Y, Curve>();

        let (lp_name, lp_symbol) = coin_helper::generate_lp_name_and_symbol<X, Y, Curve>();
        let (lp_burn_cap, lp_freeze_cap, lp_mint_cap) =
            coin::initialize<LP<X, Y, Curve>>(
                &lp_account_signer,
                lp_name,
                lp_symbol,
                6,
                true
            );
        coin::destroy_freeze_cap(lp_freeze_cap);

        let x_scale = 0;
        let y_scale = 0;

        if (curves::is_stable<Curve>()) {
            x_scale = math::pow_10(coin::decimals<X>());
            y_scale = math::pow_10(coin::decimals<Y>());
        };

        let pool = LiquidityPool<X, Y, Curve> {
            coin_x_reserve: coin::zero<X>(),
            coin_y_reserve: coin::zero<Y>(),
            last_block_timestamp: 0,
            last_price_x_cumulative: 0,
            last_price_y_cumulative: 0,
            lp_mint_cap,
            lp_burn_cap,
            x_scale,
            y_scale,
            locked: false,
            fee: global_config::get_default_fee<Curve>(),
            dao_fee: global_config::get_default_dao_fee(),
        };
        move_to(&lp_object_signer, pool);

        dao_storage::register<X, Y, Curve>(&lp_object_signer);

        event::emit(
            PoolCreatedEvent {
                pair_x: type_name<X>(),
                pair_y: type_name<Y>(),
                curve: type_name<Curve>(),
                creator: signer::address_of(acc),
                pool_address: signer::address_of(
                    &lp_object_signer
                ),
                timestamp: timestamp::now_seconds(),
            }
        );
    }

    /// Mint new liquidity coins.
    /// * `coin_x` - coin X to add to liquidity reserves.
    /// * `coin_y` - coin Y to add to liquidity reserves.
    /// Returns LP coins: `Coin<LP<X, Y, Curve>>`.
    public fun mint<X, Y, Curve>(coin_x: Coin<X>, coin_y: Coin<Y>): Coin<LP<X, Y, Curve>>
    acquires LiquidityPool, PoolAccountCapability {
        assert_no_emergency();

        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_PAIR_ORDERING);
        assert!(
            object::object_exists<LiquidityPool<X, Y, Curve>>(generate_lp_object_address<X, Y, Curve>()),
            ERR_POOL_DOES_NOT_EXIST
        );

        assert_pool_unlocked<X, Y, Curve>();

        let lp_coins_total = coin_helper::supply<LP<X, Y, Curve>>();

        let pool = borrow_global_mut<LiquidityPool<X, Y, Curve>>(generate_lp_object_address<X, Y, Curve>());
        let x_reserve_size = coin::value(&pool.coin_x_reserve);
        let y_reserve_size = coin::value(&pool.coin_y_reserve);

        let x_provided_val = coin::value<X>(&coin_x);
        let y_provided_val = coin::value<Y>(&coin_y);

        let provided_liq = if (lp_coins_total == 0) {
            let initial_liq = math::sqrt(math::mul_to_u128(x_provided_val, y_provided_val));
            assert!(initial_liq > MINIMAL_LIQUIDITY, ERR_NOT_ENOUGH_INITIAL_LIQUIDITY);
            initial_liq - MINIMAL_LIQUIDITY
        } else {
            let x_liq = math::mul_div_u128((x_provided_val as u128), lp_coins_total, (x_reserve_size as u128));
            let y_liq = math::mul_div_u128((y_provided_val as u128), lp_coins_total, (y_reserve_size as u128));
            if (x_liq < y_liq) {
                x_liq
            } else {
                y_liq
            }
        };
        assert!(provided_liq > 0, ERR_NOT_ENOUGH_LIQUIDITY);

        coin::merge(&mut pool.coin_x_reserve, coin_x);
        coin::merge(&mut pool.coin_y_reserve, coin_y);

        let lp_coins = coin::mint<LP<X, Y, Curve>>(provided_liq, &pool.lp_mint_cap);

        update_oracle<X, Y, Curve>(pool, x_reserve_size, y_reserve_size);

        event::emit(LiquidityAddedEvent {
            pair_x: type_name<X>(),
            pair_y: type_name<Y>(),
            curve: type_name<Curve>(),
            added_x_val: x_provided_val,
            added_y_val: y_provided_val,
            lp_tokens_received: provided_liq,
            timestamp: timestamp::now_seconds(),
            reserve_x: coin::value(&pool.coin_x_reserve),
            reserve_y: coin::value(&pool.coin_y_reserve),
        });
        lp_coins
    }

    /// Burn liquidity coins (LP) and get back X and Y coins from reserves.
    /// * `lp_coins` - LP coins to burn.
    /// Returns both X and Y coins - `(Coin<X>, Coin<Y>)`.
    public fun burn<X, Y, Curve>(lp_coins: Coin<LP<X, Y, Curve>>): (Coin<X>, Coin<Y>)
    acquires LiquidityPool, PoolAccountCapability {
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_PAIR_ORDERING);
        assert!(
            object::object_exists<LiquidityPool<X, Y, Curve>>(generate_lp_object_address<X, Y, Curve>()),
            ERR_POOL_DOES_NOT_EXIST
        );

        assert_pool_unlocked<X, Y, Curve>();

        let burned_lp_coins_val = coin::value(&lp_coins);

        let pool = borrow_global_mut<LiquidityPool<X, Y, Curve>>(generate_lp_object_address<X, Y, Curve>());

        let lp_coins_total = coin_helper::supply<LP<X, Y, Curve>>();
        let x_reserve_val = coin::value(&pool.coin_x_reserve);
        let y_reserve_val = coin::value(&pool.coin_y_reserve);

        // Compute x, y coin values for provided lp_coins value
        let x_to_return_val = math::mul_div_u128(
            (burned_lp_coins_val as u128),
            (x_reserve_val as u128),
            lp_coins_total
        );
        let y_to_return_val = math::mul_div_u128(
            (burned_lp_coins_val as u128),
            (y_reserve_val as u128),
            lp_coins_total
        );
        assert!(x_to_return_val > 0 && y_to_return_val > 0, ERR_INCORRECT_BURN_VALUES);

        // Withdraw those values from reserves
        let x_coin_to_return = coin::extract(&mut pool.coin_x_reserve, x_to_return_val);
        let y_coin_to_return = coin::extract(&mut pool.coin_y_reserve, y_to_return_val);

        update_oracle<X, Y, Curve>(pool, x_reserve_val, y_reserve_val);
        coin::burn(lp_coins, &pool.lp_burn_cap);

        event::emit(LiquidityRemovedEvent {
            pair_x: type_name<X>(),
            pair_y: type_name<Y>(),
            curve: type_name<Curve>(),
            returned_x_val: x_to_return_val,
            returned_y_val: y_to_return_val,
            lp_tokens_burned: burned_lp_coins_val,
            timestamp: timestamp::now_seconds(),
            reserve_x: coin::value(&pool.coin_x_reserve),
            reserve_y: coin::value(&pool.coin_y_reserve),
        });
        (x_coin_to_return, y_coin_to_return)
    }

    /// Swap coins (can swap both x and y in the same time).
    /// In the most of situation only X or Y coin argument has value (similar with *_out, only one _out will be non-zero).
    /// Because an user usually exchanges only one coin, yet function allow to exchange both coin.
    /// * `x_in` - X coins to swap.
    /// * `x_out` - expected amount of X coins to get out.
    /// * `y_in` - Y coins to swap.
    /// * `y_out` - expected amount of Y coins to get out.
    /// Returns both exchanged X and Y coins: `(Coin<X>, Coin<Y>)`.
    public fun swap<X, Y, Curve>(
        x_in: Coin<X>,
        x_out: u64,
        y_in: Coin<Y>,
        y_out: u64
    ): (Coin<X>, Coin<Y>) acquires LiquidityPool, PoolAccountCapability {
        assert_no_emergency();

        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_PAIR_ORDERING);
        assert!(
            object::object_exists<LiquidityPool<X, Y, Curve>>(generate_lp_object_address<X, Y, Curve>()),
            ERR_POOL_DOES_NOT_EXIST
        );

        assert_pool_unlocked<X, Y, Curve>();

        let x_in_val = coin::value(&x_in);
        let y_in_val = coin::value(&y_in);

        assert!(x_in_val > 0 || y_in_val > 0, ERR_EMPTY_COIN_IN);

        let pool = borrow_global_mut<LiquidityPool<X, Y, Curve>>(generate_lp_object_address<X, Y, Curve>());
        let x_reserve_size = coin::value(&pool.coin_x_reserve);
        let y_reserve_size = coin::value(&pool.coin_y_reserve);

        // Deposit new coins to liquidity pool.
        coin::merge(&mut pool.coin_x_reserve, x_in);
        coin::merge(&mut pool.coin_y_reserve, y_in);

        // Withdraw expected amount from reserves.
        let x_swapped = coin::extract(&mut pool.coin_x_reserve, x_out);
        let y_swapped = coin::extract(&mut pool.coin_y_reserve, y_out);

        // Confirm that lp_value for the pool hasn't been reduced.
        // For that, we compute lp_value with old reserves and lp_value with reserves after swap is done,
        // and make sure lp_value doesn't decrease
        let (x_res_new_after_fee, y_res_new_after_fee) =
            new_reserves_after_fees_scaled<Curve>(
                coin::value(&pool.coin_x_reserve),
                coin::value(&pool.coin_y_reserve),
                x_in_val,
                y_in_val,
                pool.fee
            );
        assert_lp_value_is_increased<Curve>(
            pool.x_scale,
            pool.y_scale,
            (x_reserve_size as u128),
            (y_reserve_size as u128),
            x_res_new_after_fee,
            y_res_new_after_fee,
        );

        split_fee_to_dao(pool, x_in_val, y_in_val);

        update_oracle<X, Y, Curve>(pool, x_reserve_size, y_reserve_size);

        event::emit(SwapEvent {
            pair_x: type_name<X>(),
            pair_y: type_name<Y>(),
            curve: type_name<Curve>(),
            x_in: x_in_val,
            y_in: y_in_val,
            x_out,
            y_out,
            timestamp: timestamp::now_seconds(),
            reserve_x: coin::value(&pool.coin_x_reserve),
            reserve_y: coin::value(&pool.coin_y_reserve),
        });
        // Return swapped amount.
        (x_swapped, y_swapped)
    }

    // Private functions.

    /// Get reserves after fees.
    /// * `x_reserve` - reserve X.
    /// * `y_reserve` - reserve Y.
    /// * `x_in_val` - amount of X coins added to reserves.
    /// * `y_in_val` - amount of Y coins added to reserves.
    /// * `fee` - amount of fee.
    /// Returns both X and Y reserves after fees.
    fun new_reserves_after_fees_scaled<Curve>(
        x_reserve: u64,
        y_reserve: u64,
        x_in_val: u64,
        y_in_val: u64,
        fee: u64,
    ): (u128, u128) {
        let x_res_new_after_fee = if (curves::is_uncorrelated<Curve>()) {
            math::mul_to_u128(x_reserve, FEE_SCALE) - math::mul_to_u128(x_in_val, fee)
        } else if (curves::is_stable<Curve>()) {
            ((x_reserve - math::mul_div(x_in_val, fee, FEE_SCALE)) as u128)
        } else {
            abort ERR_UNREACHABLE
        };

        let y_res_new_after_fee = if (curves::is_uncorrelated<Curve>()) {
            math::mul_to_u128(y_reserve, FEE_SCALE) - math::mul_to_u128(y_in_val, fee)
        } else if (curves::is_stable<Curve>()) {
            ((y_reserve - math::mul_div(y_in_val, fee, FEE_SCALE)) as u128)
        } else {
            abort ERR_UNREACHABLE
        };

        (x_res_new_after_fee, y_res_new_after_fee)
    }

    /// Depositing part of fees to DAO Storage.
    /// * `pool` - pool to extract coins.
    /// * `x_in_val` - how much X coins was deposited to pool.
    /// * `y_in_val` - how much Y coins was deposited to pool.
    fun split_fee_to_dao<X, Y, Curve>(
        pool: &mut LiquidityPool<X, Y, Curve>,
        x_in_val: u64,
        y_in_val: u64
    ) acquires PoolAccountCapability {
        let fee_multiplier = pool.fee;
        let dao_fee = pool.dao_fee;
        // Split dao_fee_multiplier% of fee multiplier of provided coins to the DAOStorage
        let dao_fee_multiplier = if (fee_multiplier * dao_fee % DAO_FEE_SCALE != 0) {
            (fee_multiplier * dao_fee / DAO_FEE_SCALE) + 1
        } else {
            fee_multiplier * dao_fee / DAO_FEE_SCALE
        };
        let dao_x_fee_val = math::mul_div(x_in_val, dao_fee_multiplier, FEE_SCALE);
        let dao_y_fee_val = math::mul_div(y_in_val, dao_fee_multiplier, FEE_SCALE);

        let dao_x_in = coin::extract(&mut pool.coin_x_reserve, dao_x_fee_val);
        let dao_y_in = coin::extract(&mut pool.coin_y_reserve, dao_y_fee_val);
        let pool_addr = generate_lp_object_address<X, Y, Curve>();
        dao_storage::deposit<X, Y, Curve>(pool_addr, dao_x_in, dao_y_in);
    }

    /// Compute and verify LP value after and before swap, in nutshell, _k function.
    /// * `x_scale` - 10 pow by X coin decimals.
    /// * `y_scale` - 10 pow by Y coin decimals.
    /// * `x_res` - X reserves before swap.
    /// * `y_res` - Y reserves before swap.
    /// * `x_res_with_fees` - X reserves after swap.
    /// * `y_res_with_fees` - Y reserves after swap.
    /// Aborts if swap can't be done.
    fun assert_lp_value_is_increased<Curve>(
        x_scale: u64,
        y_scale: u64,
        x_res: u128,
        y_res: u128,
        x_res_with_fees: u128,
        y_res_with_fees: u128,
    ) {
        if (curves::is_stable<Curve>()) {
            let lp_value_before_swap = stable_curve::lp_value(x_res, x_scale, y_res, y_scale);
            let lp_value_after_swap_and_fee = stable_curve::lp_value(
                x_res_with_fees,
                x_scale,
                y_res_with_fees,
                y_scale
            );

            assert!(lp_value_after_swap_and_fee > lp_value_before_swap, ERR_INCORRECT_SWAP);
        } else if (curves::is_uncorrelated<Curve>()) {
            let lp_value_before_swap = x_res * y_res;
            let lp_value_before_swap_u256 = (lp_value_before_swap as u256) * (FEE_SCALE as u256) * (FEE_SCALE as u256);
            let lp_value_after_swap_and_fee = (x_res_with_fees as u256) * (y_res_with_fees as u256);

            assert!(lp_value_after_swap_and_fee > lp_value_before_swap_u256, ERR_INCORRECT_SWAP);
        } else {
            abort ERR_UNREACHABLE
        };
    }

    /// Update current cumulative prices.
    /// Important: If you want to use the following function take into account prices can be overflowed.
    /// So it's important to use same logic in your math/algo (as Move doesn't allow overflow). See math::overflow_add.
    /// * `pool` - Liquidity pool to update prices.
    /// * `x_reserve` - coin X reserves.
    /// * `y_reserve` - coin Y reserves.
    fun update_oracle<X, Y, Curve>(
        pool: &mut LiquidityPool<X, Y, Curve>,
        x_reserve: u64,
        y_reserve: u64
    ) {
        let last_block_timestamp = pool.last_block_timestamp;

        let block_timestamp = timestamp::now_seconds();

        let time_elapsed = ((block_timestamp - last_block_timestamp) as u128);

        if (time_elapsed > 0 && x_reserve != 0 && y_reserve != 0) {
            let last_price_x_cumulative = uq64x64::to_u128(uq64x64::fraction(y_reserve, x_reserve)) * time_elapsed;
            let last_price_y_cumulative = uq64x64::to_u128(uq64x64::fraction(x_reserve, y_reserve)) * time_elapsed;

            pool.last_price_x_cumulative = math::overflow_add(pool.last_price_x_cumulative, last_price_x_cumulative);
            pool.last_price_y_cumulative = math::overflow_add(pool.last_price_y_cumulative, last_price_y_cumulative);

            event::emit(OracleUpdatedEvent {
                pair_x: type_name<X>(),
                pair_y: type_name<Y>(),
                curve: type_name<Curve>(),
                last_price_x_cumulative: pool.last_price_x_cumulative,
                last_price_y_cumulative: pool.last_price_y_cumulative,
                timestamp: block_timestamp,
            });
        };

        pool.last_block_timestamp = block_timestamp;
    }

    /// Aborts if pool is locked.
    fun assert_pool_unlocked<X, Y, Curve>() acquires LiquidityPool, PoolAccountCapability {
        let pool = borrow_global<LiquidityPool<X, Y, Curve>>(generate_lp_object_address<X, Y, Curve>());
        assert!(pool.locked == false, ERR_POOL_IS_LOCKED);
    }

    // Getters.

    #[view]
    /// Check if pool is locked.
    public fun is_pool_locked<X, Y, Curve>(): bool acquires LiquidityPool, PoolAccountCapability {
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_PAIR_ORDERING);
        assert!(
            object::object_exists<LiquidityPool<X, Y, Curve>>(generate_lp_object_address<X, Y, Curve>()),
            ERR_POOL_DOES_NOT_EXIST
        );

        let pool = borrow_global<LiquidityPool<X, Y, Curve>>(generate_lp_object_address<X, Y, Curve>());
        pool.locked
    }

    #[view]
    /// Get reserves of a pool.
    /// Returns both (X, Y) reserves.
    public fun get_reserves_size<X, Y, Curve>(): (u64, u64)
    acquires LiquidityPool, PoolAccountCapability {
        assert_no_emergency();

        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_PAIR_ORDERING);
        assert!(
            object::object_exists<LiquidityPool<X, Y, Curve>>(generate_lp_object_address<X, Y, Curve>()),
            ERR_POOL_DOES_NOT_EXIST
        );

        assert_pool_unlocked<X, Y, Curve>();

        let liquidity_pool = borrow_global<LiquidityPool<X, Y, Curve>>(generate_lp_object_address<X, Y, Curve>());
        let x_reserve = coin::value(&liquidity_pool.coin_x_reserve);
        let y_reserve = coin::value(&liquidity_pool.coin_y_reserve);

        (x_reserve, y_reserve)
    }

    #[view]
    /// Get current cumulative prices.
    /// Cumulative prices can be overflowed, so take it into account before work with the following function.
    /// It's important to use same logic in your math/algo (as Move doesn't allow overflow).
    /// Returns (X price, Y price, block_timestamp).
    public fun get_cumulative_prices<X, Y, Curve>(): (u128, u128, u64)
    acquires LiquidityPool, PoolAccountCapability {
        assert_no_emergency();

        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_PAIR_ORDERING);
        assert!(
            object::object_exists<LiquidityPool<X, Y, Curve>>(generate_lp_object_address<X, Y, Curve>()),
            ERR_POOL_DOES_NOT_EXIST
        );

        assert_pool_unlocked<X, Y, Curve>();

        let liquidity_pool = borrow_global<LiquidityPool<X, Y, Curve>>(generate_lp_object_address<X, Y, Curve>());
        let last_price_x_cumulative = *&liquidity_pool.last_price_x_cumulative;
        let last_price_y_cumulative = *&liquidity_pool.last_price_y_cumulative;
        let last_block_timestamp = liquidity_pool.last_block_timestamp;

        (last_price_x_cumulative, last_price_y_cumulative, last_block_timestamp)
    }


    #[view]
    /// Get decimals scales (10^X decimals, 10^Y decimals) for stable curve.
    /// For uncorrelated curve would return just zeros.
    public fun get_decimals_scales<X, Y, Curve>(): (u64, u64) acquires LiquidityPool, PoolAccountCapability {
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_PAIR_ORDERING);
        assert!(exists<LiquidityPool<X, Y, Curve>>(generate_lp_object_address<X, Y, Curve>()), ERR_POOL_DOES_NOT_EXIST);

        let pool = borrow_global<LiquidityPool<X, Y, Curve>>(generate_lp_object_address<X, Y, Curve>());
        (pool.x_scale, pool.y_scale)
    }

    #[view]
    /// Check if liquidity pool exists.
    public fun is_pool_exists<X, Y, Curve>(): bool acquires PoolAccountCapability {
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_PAIR_ORDERING);
        exists<LiquidityPool<X, Y, Curve>>(generate_lp_object_address<X, Y, Curve>())
    }

    #[view]
    /// Get fee for specific pool together with denominator (numerator, denominator).
    public fun get_fees_config<X, Y, Curve>(): (u64, u64) acquires LiquidityPool, PoolAccountCapability {
        (get_fee<X, Y, Curve>(), FEE_SCALE)
    }

    /// Get fee for specific pool.
    public fun get_fee<X, Y, Curve>(): u64 acquires LiquidityPool, PoolAccountCapability {
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_PAIR_ORDERING);
        assert!(exists<LiquidityPool<X, Y, Curve>>(generate_lp_object_address<X, Y, Curve>()), ERR_POOL_DOES_NOT_EXIST);

        let pool = borrow_global<LiquidityPool<X, Y, Curve>>(generate_lp_object_address<X, Y, Curve>());
        pool.fee
    }

    /// Set fee for specific pool.
    public entry fun set_fee<X, Y, Curve>(fee_admin: &signer, fee: u64) acquires LiquidityPool, PoolAccountCapability {
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_PAIR_ORDERING);
        assert!(exists<LiquidityPool<X, Y, Curve>>(generate_lp_object_address<X, Y, Curve>()), ERR_POOL_DOES_NOT_EXIST);
        assert_pool_unlocked<X, Y, Curve>();
        assert!(signer::address_of(fee_admin) == global_config::get_fee_admin(), ERR_NOT_ADMIN);

        global_config::assert_valid_fee(fee);

        let pool = borrow_global_mut<LiquidityPool<X, Y, Curve>>(generate_lp_object_address<X, Y, Curve>());
        pool.fee = fee;

        event::emit(UpdateFeeEvent {
            pair_x: type_name<X>(),
            pair_y: type_name<Y>(),
            curve: type_name<Curve>(),
            new_fee: fee,
            timestamp: timestamp::now_seconds(),
        });
    }

    #[view]
    /// Get DAO fee for specific pool together with denominator (numerator, denominator).
    public fun get_dao_fees_config<X, Y, Curve>(): (u64, u64) acquires LiquidityPool, PoolAccountCapability {
        (get_dao_fee<X, Y, Curve>(), DAO_FEE_SCALE)
    }

    /// Get DAO fee for specific pool.
    public fun get_dao_fee<X, Y, Curve>(): u64 acquires LiquidityPool, PoolAccountCapability {
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_PAIR_ORDERING);
        assert!(
            object::object_exists<LiquidityPool<X, Y, Curve>>(generate_lp_object_address<X, Y, Curve>()),
            ERR_POOL_DOES_NOT_EXIST
        );

        let pool = borrow_global<LiquidityPool<X, Y, Curve>>(generate_lp_object_address<X, Y, Curve>());
        pool.dao_fee
    }

    /// Set DAO fee for specific pool.
    public entry fun set_dao_fee<X, Y, Curve>(
        fee_admin: &signer,
        dao_fee: u64
    ) acquires LiquidityPool, PoolAccountCapability {
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_PAIR_ORDERING);
        assert!(
            object::object_exists<LiquidityPool<X, Y, Curve>>(generate_lp_object_address<X, Y, Curve>()),
            ERR_POOL_DOES_NOT_EXIST
        );
        assert_pool_unlocked<X, Y, Curve>();
        assert!(signer::address_of(fee_admin) == global_config::get_fee_admin(), ERR_NOT_ADMIN);

        global_config::assert_valid_dao_fee(dao_fee);

        let pool = borrow_global_mut<LiquidityPool<X, Y, Curve>>(generate_lp_object_address<X, Y, Curve>());
        pool.dao_fee = dao_fee;

        event::emit(UpdateDAOFeeEvent {
            pair_x: type_name<X>(),
            pair_y: type_name<Y>(),
            curve: type_name<Curve>(),
            new_fee: dao_fee,
            timestamp: timestamp::now_seconds(),
        });
    }

    #[test_only]
    public fun compute_and_verify_lp_value_for_test<Curve>(
        x_scale: u64,
        y_scale: u64,
        x_res: u128,
        y_res: u128,
        x_res_new: u128,
        y_res_new: u128,
    ) {
        assert_lp_value_is_increased<Curve>(
            x_scale,
            y_scale,
            x_res,
            y_res,
            x_res_new,
            y_res_new,
        )
    }

    #[test_only]
    public fun update_cumulative_price_for_test<X, Y>(
        test_account: &signer,
        prev_last_block_timestamp: u64,
        prev_last_price_x_cumulative: u128,
        prev_last_price_y_cumulative: u128,
        x_reserve: u64,
        y_reserve: u64,
    ): (u128, u128, u64) acquires LiquidityPool, PoolAccountCapability {
        register<X, Y, curves::Uncorrelated>(test_account);

        let pool =
            borrow_global_mut<LiquidityPool<X, Y, curves::Uncorrelated>>(
                generate_lp_object_address<X, Y, curves::Uncorrelated>()
            );
        pool.last_block_timestamp = prev_last_block_timestamp;
        pool.last_price_x_cumulative = prev_last_price_x_cumulative;
        pool.last_price_y_cumulative = prev_last_price_y_cumulative;

        update_oracle(pool, x_reserve, y_reserve);

        (pool.last_price_x_cumulative, pool.last_price_y_cumulative, pool.last_block_timestamp)
    }
}

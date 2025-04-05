/// Copyright (C) 2024 -- Supra
/// 
/// This module allows anyone to create `slot`. Every slot has a `max_deposit_limit`, up to which
/// users can `lockin()` the amount subjected to `min_deposit_per_txn` and subjected to minimum
/// 1 FULL COIN of a given `CoinType`. No partial coins are allowed to be deposited.abort_code
///
/// The `creator` should create these slot with the intention to fund enough rewards so that
/// a users after the `maturity_time` can `claim()` their original principle that they locked in
/// along with the rewards which should be `principle * return_percentage / REWARD_DECIMAL * REWARD_PERCENTAGE_DENOMINATOR`
///
///
/// While anyone can `fund_rewards()` to a given slot, it would be a moral responsibility (
/// and legal responsibility if advertised as such) of the `creator` to ensure that before the
/// `maturity_time`, a slot has sufficient `rewards_available` so as to cover total rewards
/// in proportion to the `total_deposit * return_percentage / REWARD_DECIMALS * REWARD_PERCENTAGE_DENOMINATOR`
///
/// Rewards once funded can never be withdrawn by anyone from the resource account created for every slot
/// except by a user who locked in some principle. Such a user can claim their principle along with their
/// proportional reward.
///
///
/// Deposit can be made only after `slot_start_time`
///
/// Deposit can be made only before `slot_start_time + slot_deposit_duration`
///
/// The very fist deposit to the slot would set the maturity/unlocking time to `first_deposit_time +
/// slot_lockin_duration`.
///
/// A user can only `claim()` their principle and rewards after `maturity_time`. If `rewards_available`
/// is less than a reward that a user deserves at the time of `claim()` , the `claim()` would fail.
///

module supra_admin::genesis_vault {
    use std::error;
    use std::signer;
    use std::vector;
    use std::bcs;
    use std::string::String;
    use supra_framework::timestamp;
    use aptos_std::table::{Self, Table};
    use aptos_std::type_info;
    use supra_framework::account;
    use supra_framework::supra_account;
    use supra_framework::account::SignerCapability;

    use supra_framework::event::emit;
    use supra_framework::coin;
    #[test_only]
    use supra_framework::supra_coin;
    #[test_only]
    use supra_framework::supra_coin::SupraCoin;

    /// Vector size is not matching with the condition
    const EVECTOR_SIZE_MISMATCH: u64 = 1;
    /// The slot does not exists
    const ESLOT_NOT_EXIST: u64 = 2;
    /// The slot is already closed
    const ESLOT_CLOSED: u64 = 3;
    /// The Amount deposited is lower than the min amount
    const ELOW_DEPOSIT_AMOUNT: u64 = 4;
    /// The slot is filled with max capacity
    const ESLOT_ALREADY_FILLED: u64 = 5;
    /// Slot is still locked
    const ENOT_MATURED: u64 = 6;
    /// User has not participated or already claimed in this slot
    const ENOT_PARTICIPATED_OR_ALREADY_CLAIMED: u64 = 7;
    /// Rewards Not Available in this slot
    const EREWARDS_NOT_AVAILABLE: u64 = 8;
    /// The pool start time is less than current time
    const ESTART_TIME_TOO_OLD: u64 = 9;
    /// Undefined expression
    const EUNDEFIND_EXP: u64 = 10;
    /// Token amount in decimals are not accepted
    const EDECIMALS_NOT_ACCEPTED: u64 = 11;
    /// The slot is not started yet for deposit
    const ESLOT_NOT_STARTED: u64 = 12;
    /// The lockin duration needs to be greater than the deposit duration
    const EINVALID_LOCKIN_DURAION: u64 = 13;
    /// The reward user is sending into the slots is more than the required amount
    const EEXCESSIVE_REWARD: u64 = 14;
    /// Min deposit per txn needs to be less than max deposit
    const EDEPOSIT_CONSTRAINTS_MISMATCH: u64 = 15;

    const REWARD_DECIMALS: u64 = 100;
    const REWARD_PERCENTAGE_DENOMINATOR: u64 = 100;

    #[event]
    struct UserDepositEvent has store, drop {
        user_address: address,
        slot_address: address,
        deposit_amount: u64,
        deposit_time: u64,
        maturity_time: u64
    }

    #[event]
    struct UserClaimedEvent has store, drop {
        user_address: address,
        slot_address: address,
        deposits: u64,
        reward: u64,
        withdraw_time: u64
    }

    #[event]
    struct SlotCreated has store, drop {
        creator_address: address,
        slot_address: address,
        slot_seed: vector<u8>,
        max_deposit: u64,
        min_deposit_per_txn: u64,
        start_time: u64,
        end_time: u64,
        return_percentage: u64,
        coin_type: String
    }

    #[event]
    struct RewardsAdded has store, drop {
        user_address: address,
        slot_address: address,
        amount: u64
    }

    struct SlotConfig<phantom CoinType> has key {
        /// time at which slots open for lock-in
        start_time: u64,
        /// duration after `start_time` during which locking in amount is allowed (in seconds)
        slot_deposit_duration: u64,
        /// duration for which the amount would be locked in (in seconds)
        lockin_duration: u64,
        /// The value needs to be provided wrt 2 decimal places so 10% will be 1000
        return_percentage: u64,
        /// the time at which the amount along with rewards can be claimed (unix timestamp in seconds)
        maturity_time: u64,
        /// rewards in the given slot available
        rewards_available: u64,
        /// upper limit on how much total lock-in is allowed
        max_deposit_limit: u64,
        /// minimum deposit that need to be made per txn
        min_deposit_per_txn: u64,
        /// total amount that was ever locked in the slot, this only increases
        total_deposit: u64,
        /// amount that is available at the moment in the slot as principle locked in
        current_deposit: u64,
        slot_signer_cap: SignerCapability,
        /// map from the users -> total amount they locked in
        user_deposits: Table<address, u64>
    }

    struct SlotDetails<phantom CoinType> has copy, drop {
        /// time at which slots open for lock-in
        start_time: u64,
        /// duration after `start_time` during which locking in amount is allowed (in seconds)
        slot_deposit_duration: u64,
        /// duration for which the amount would be locked in (in seconds)
        lockin_duration: u64,
        /// The value needs to be provided wrt 2 decimal places so 10% will be 1000
        return_percentage: u64,
        /// the time at which the amount along with rewards can be claimed (unix timestamp in seconds)
        maturity_time: u64,
        /// rewards in the given slot available
        rewards_available: u64,
        /// upper limit on how much total lock-in is allowed
        max_deposit_limit: u64,
        /// minimum deposit that need to be made per txn
        min_deposit_per_txn: u64,
        /// total amount that was ever locked in the slot, this only increases
        total_deposit: u64,
        /// amount that is available at the moment in the slot as principle locked in
        current_deposit: u64
    }

    /// Pre-condition: If a `creator` uses the same parameter to create two different slots, the
    /// slot creation may fail due to collision in `resource_account` creation. Therefore, it is
    /// responsibility of `creator` to ensure that `seed` provided is different, if all other
    /// parameters are the same while creating multiple slots.
    public entry fun create_slot<CoinType>(
        creator: &signer,
        max_deposit: u64,
        lockin_duration: u64,
        slot_start_time: u64,
        slot_return_percentage: u64,
        slot_deposit_duration: u64,
        min_deposit_per_txn: u64,
        seed: vector<u8>
    ) {
        assert!(
            slot_start_time > timestamp::now_seconds(),
            error::aborted(ESTART_TIME_TOO_OLD)
        );
        assert!(
            min_deposit_per_txn <= max_deposit,
            error::aborted(EDEPOSIT_CONSTRAINTS_MISMATCH)
        );
        assert!(
            slot_deposit_duration < lockin_duration,
            error::aborted(EINVALID_LOCKIN_DURAION)
        );
        validate_token_amount<CoinType>(max_deposit);
        validate_token_amount<CoinType>(min_deposit_per_txn);

        vector::append(&mut seed, bcs::to_bytes(&slot_deposit_duration));
        vector::append(&mut seed, bcs::to_bytes(&slot_return_percentage));
        vector::append(&mut seed, bcs::to_bytes(&slot_start_time));
        vector::append(&mut seed, bcs::to_bytes(&max_deposit));
        vector::append(&mut seed, bcs::to_bytes(&min_deposit_per_txn));

        let (slot_signer, slot_signer_capability) =
            account::create_resource_account(creator, seed);
        let slot_address = signer::address_of(&slot_signer);

        move_to(
            &slot_signer,
            SlotConfig<CoinType> {
                start_time: slot_start_time,
                slot_deposit_duration,
                lockin_duration,
                return_percentage: slot_return_percentage,
                maturity_time: 0,
                rewards_available: 0,
                max_deposit_limit: max_deposit,
                min_deposit_per_txn,
                total_deposit: 0,
                current_deposit: 0,
                slot_signer_cap: slot_signer_capability,
                user_deposits: table::new<address, u64>()
            }
        );
        emit(
            SlotCreated {
                creator_address: signer::address_of(creator),
                slot_address,
                slot_seed: seed,
                max_deposit,
                min_deposit_per_txn,
                start_time: slot_start_time,
                end_time: slot_start_time + slot_deposit_duration,
                return_percentage: slot_return_percentage,
                coin_type: type_info::type_name<CoinType>()
            }
        );
    }

    public entry fun lockin<CoinType>(
        user: &signer, slot: address, amount: u64
    ) acquires SlotConfig {
        assert!(
            is_exist<CoinType>(slot),
            error::invalid_argument(ESLOT_NOT_EXIST)
        );
        validate_token_amount<CoinType>(amount);
        let slot_details = borrow_global_mut<SlotConfig<CoinType>>(slot);

        // `lockin` is not allowed before `start_time`
        assert!(
            timestamp::now_seconds() >= slot_details.start_time,
            error::permission_denied(ESLOT_NOT_STARTED)
        );

        // `lockin` is not allowed after `start_time + slot_deposit_duration`
        assert!(
            timestamp::now_seconds()
                <= slot_details.start_time + slot_details.slot_deposit_duration,
            error::permission_denied(ESLOT_CLOSED)
        );

        // `lockin` is subjected to `min_deposit_per_txn` restriction
        assert!(
            amount >= slot_details.min_deposit_per_txn,
            error::permission_denied(ELOW_DEPOSIT_AMOUNT)
        );

        // `lockin` is subjected to upper limit of the slot
        assert!(
            (amount as u128) + (slot_details.current_deposit as u128)
                <= (slot_details.max_deposit_limit as u128),
            error::permission_denied(ESLOT_ALREADY_FILLED)
        );
        supra_account::transfer_coins<CoinType>(user, slot, amount);

        // If this is the first deposit, set the `maturity_time` to `lockin_duration` from now
        if (slot_details.maturity_time == 0) {
            slot_details.maturity_time = timestamp::now_seconds()
                + slot_details.lockin_duration;
        };
        slot_details.current_deposit = slot_details.current_deposit + amount;

        // Track maximum deposit the slot ever had at any point in time
        slot_details.total_deposit = slot_details.total_deposit + amount;
        let user_address = signer::address_of(user);
        let user_deposit =
            table::borrow_mut_with_default(
                &mut slot_details.user_deposits,
                user_address,
                0
            );
        *user_deposit = *user_deposit + amount;

        emit(
            UserDepositEvent {
                user_address: signer::address_of(user),
                slot_address: slot,
                deposit_amount: amount,
                deposit_time: timestamp::now_seconds(),
                maturity_time: slot_details.maturity_time
            }
        )
    }

    public entry fun claim<CoinType>(user: address, slot: address) acquires SlotConfig {
        assert!(
            is_exist<CoinType>(slot),
            error::invalid_argument(ESLOT_NOT_EXIST)
        );
        let slot_details = borrow_global_mut<SlotConfig<CoinType>>(slot);

        // `claim()` can only succeed after `maturity_time` is over
        assert!(
            timestamp::now_seconds() > slot_details.maturity_time,
            error::permission_denied(ENOT_MATURED)
        );

        //User has to have locked in amount in the slot
        assert!(
            table::contains(&slot_details.user_deposits, user),
            error::not_found(ENOT_PARTICIPATED_OR_ALREADY_CLAIMED)
        );

        // There is no partial claim, so remove the user and refund full amount along with reward
        let user_deposit = table::remove(&mut slot_details.user_deposits, user);
        let rewards_gathered = calculate_reward(user_deposit, slot_details.return_percentage);
        assert!(
            rewards_gathered <= slot_details.rewards_available,
            error::unavailable(EREWARDS_NOT_AVAILABLE)
        );
        let claimed_amount = user_deposit + rewards_gathered;

        // subtraction is safe since `current_deposit` at any given time would be sum of all
        // `user_deposit` who has not claimed
        slot_details.current_deposit = slot_details.current_deposit - user_deposit;

        // subtraction is safe due to assertion above that checks if enough rewards are available
        slot_details.rewards_available = slot_details.rewards_available
            - rewards_gathered;
        coin::transfer<CoinType>(
            &account::create_signer_with_capability(&slot_details.slot_signer_cap),
            user,
            claimed_amount
        );

        emit(
            UserClaimedEvent {
                user_address: user,
                slot_address: slot,
                deposits: user_deposit,
                reward: rewards_gathered,
                withdraw_time: timestamp::now_seconds()
            }
        )
    }

    public entry fun fund_reward<CoinType>(
        funder: &signer, slot: address, amount: u64
    ) acquires SlotConfig {
        assert!(
            is_exist<CoinType>(slot),
            error::invalid_argument(ESLOT_NOT_EXIST)
        );
        let slot_details = borrow_global_mut<SlotConfig<CoinType>>(slot);
        assert!(
            amount + slot_details.rewards_available <= calculate_reward(
                slot_details.current_deposit,
                slot_details.return_percentage
            ) + 1,
            error::aborted(EEXCESSIVE_REWARD)
        );

        supra_account::transfer_coins<CoinType>(funder, slot, amount);
        slot_details.rewards_available = slot_details.rewards_available + amount;

        emit(
            RewardsAdded {
                user_address: signer::address_of(funder),
                slot_address: slot,
                amount
            }
        );
    }

    #[view]
    public fun is_exist<CoinType>(slot: address): bool {
        exists<SlotConfig<CoinType>>(slot)
    }

    /// Return (slot_start_time,slot deposit duration, lockin duration, return_percentage, maturity time, rewards available, total deposit limit, Min deposit per txn, total deposited amount, current deposited amount)
    public fun slot_details_destructured<CoinType>(
        slot_details: SlotDetails<CoinType>
    ): (u64, u64, u64, u64, u64, u64, u64, u64, u64, u64) {
        (
            slot_details.start_time,
            slot_details.slot_deposit_duration,
            slot_details.lockin_duration,
            slot_details.return_percentage,
            slot_details.maturity_time,
            slot_details.rewards_available,
            slot_details.max_deposit_limit,
            slot_details.min_deposit_per_txn,
            slot_details.total_deposit,
            slot_details.current_deposit
        )
    }

    #[view]
    public fun slot_details<CoinType>(slot: address): SlotDetails<CoinType> acquires SlotConfig {
        assert!(
            is_exist<CoinType>(slot),
            error::invalid_argument(ESLOT_NOT_EXIST)
        );
        let slot_config = borrow_global<SlotConfig<CoinType>>(slot);
        SlotDetails<CoinType> {
            start_time: slot_config.start_time,
            slot_deposit_duration: slot_config.slot_deposit_duration,
            lockin_duration: slot_config.lockin_duration,
            return_percentage: slot_config.return_percentage,
            maturity_time: slot_config.maturity_time,
            rewards_available: slot_config.rewards_available,
            max_deposit_limit: slot_config.max_deposit_limit,
            min_deposit_per_txn: slot_config.min_deposit_per_txn,
            total_deposit: slot_config.total_deposit,
            current_deposit: slot_config.current_deposit
        }
    }

    #[view]
    public fun user_deposits<CoinType>(
        user: address, slots: vector<address>
    ): vector<u64> acquires SlotConfig {
        let current_user_deposits: vector<u64> = vector::empty();
        vector::for_each_ref(
            &slots,
            |slot| {
                assert!(
                    is_exist<CoinType>(*slot),
                    error::invalid_argument(ESLOT_NOT_EXIST)
                );
                vector::push_back(
                    &mut current_user_deposits,
                    *table::borrow_with_default(
                        &borrow_global<SlotConfig<CoinType>>(*slot).user_deposits,
                        user,
                        &0
                    )
                );
            }
        );
        current_user_deposits
    }

    fun calculate_reward(amount: u64, return_percentage: u64): u64 {
        (((amount as u128) * (return_percentage as u128))
            / ((REWARD_DECIMALS * REWARD_PERCENTAGE_DENOMINATOR) as u128) as u64)
    }

    #[view]
    public fun slot_deposits<CoinType>(slots: vector<address>): vector<u64> acquires SlotConfig {
        let current_slot_deposits: vector<u64> = vector::empty();
        vector::for_each_ref(
            &slots,
            |slot| {
                assert!(
                    is_exist<CoinType>(*slot),
                    error::invalid_argument(ESLOT_NOT_EXIST)
                );
                vector::push_back(
                    &mut current_slot_deposits,
                    borrow_global<SlotConfig<CoinType>>(*slot).total_deposit
                );
            }
        );
        current_slot_deposits
    }

    public fun validate_token_amount<CoinType>(amount: u64) {
        assert!(
            (amount as u256)
                % calculate_power(
                (10 as u128),
                (coin::decimals<CoinType>() as u16)
            ) == (0 as u256),
            error::permission_denied(EDECIMALS_NOT_ACCEPTED)
        );
    }

    #[view]
    /// Calculates the power of a base raised to an exponent. The result of `base` raised to the power of `exponent`
    public fun calculate_power(base: u128, exponent: u16): u256 {
        let result: u256 = 1;
        let base: u256 = (base as u256);
        assert!(
            (base | (exponent as u256)) != 0,
            error::internal(EUNDEFIND_EXP)
        );
        if (base == 0) {
            return 0
        };
        while (exponent != 0) {
            if ((exponent & 0x1) == 1) {
                result = result * base;
            };
            base = base * base;
            exponent = (exponent >> 1);
        };
        result
    }

    #[view]
    /// Returns the scale of reward percent
    public fun get_reward_percent_decimals(): u64 {
        return REWARD_DECIMALS
    }

    #[test_only]
    fun create_multiple_slots(
        creator: &signer,
        max_deposit: vector<u64>,
        lockin_duration: vector<u64>,
        slot_start_time: vector<u64>,
        slot_return_percentage: vector<u64>,
        slot_deposit_duration: vector<u64>,
        min_deposit_per_txn: vector<u64>
    ): vector<address> {
        let slot_addresses: vector<address> = vector[];
        assert!(
            vector::length(&max_deposit) == vector::length(&lockin_duration),
            error::aborted(EVECTOR_SIZE_MISMATCH)
        );
        assert!(
            vector::length(&max_deposit) == vector::length(&min_deposit_per_txn),
            error::aborted(EVECTOR_SIZE_MISMATCH)
        );
        assert!(
            vector::length(&max_deposit) == vector::length(&slot_return_percentage),
            error::aborted(EVECTOR_SIZE_MISMATCH)
        );
        assert!(
            vector::length(&max_deposit) == vector::length(&slot_deposit_duration),
            error::aborted(EVECTOR_SIZE_MISMATCH)
        );
        assert!(
            vector::length(&max_deposit) == vector::length(&slot_start_time),
            error::aborted(EVECTOR_SIZE_MISMATCH)
        );
        for (i in 0..vector::length(&max_deposit)) {
            let seed = bcs::to_bytes(&i);
            let max_deposit_ = vector::pop_back(&mut max_deposit);
            let lockin_duration_ = vector::pop_back(&mut lockin_duration);
            let slot_start_time_ = vector::pop_back(&mut slot_start_time);
            let slot_return_percentage_ = vector::pop_back(&mut slot_return_percentage);
            let slot_deposit_duration_ = vector::pop_back(&mut slot_deposit_duration);
            let min_deposit_per_txn_ = vector::pop_back(&mut min_deposit_per_txn);
            create_slot<SupraCoin>(
                creator,
                max_deposit_,
                lockin_duration_,
                slot_start_time_,
                slot_return_percentage_,
                slot_deposit_duration_,
                min_deposit_per_txn_,
                seed
            );

            vector::append(&mut seed, bcs::to_bytes(&slot_deposit_duration_));
            vector::append(&mut seed, bcs::to_bytes(&slot_return_percentage_));
            vector::append(&mut seed, bcs::to_bytes(&slot_start_time_));
            vector::append(&mut seed, bcs::to_bytes(&max_deposit_));
            vector::append(&mut seed, bcs::to_bytes(&min_deposit_per_txn_));

            let slot_address =
                account::create_resource_address(&signer::address_of(creator), seed);
            vector::push_back(&mut slot_addresses, slot_address);
        };

        slot_addresses
    }

    #[test_only]
    const ONE_SUPRA: u64 = 100_000_000;

    #[test_only]
    fun create_slots_and_add_funds(
        supra_framework: &signer,
        creator: &signer,
        first_user: &signer,
        second_user: &signer
    ): vector<address> {
        timestamp::set_time_has_started_for_testing(supra_framework);
        let (burn_cap, min_cap) = supra_coin::initialize_for_test(supra_framework);
        supra_account::deposit_coins<SupraCoin>(
            signer::address_of(creator),
            coin::mint<SupraCoin>(10000 * ONE_SUPRA, &min_cap)
        );
        supra_account::deposit_coins<SupraCoin>(
            signer::address_of(first_user),
            coin::mint<SupraCoin>(10000 * ONE_SUPRA, &min_cap)
        );
        supra_account::deposit_coins<SupraCoin>(
            signer::address_of(second_user),
            coin::mint<SupraCoin>(10000 * ONE_SUPRA, &min_cap)
        );

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(min_cap);

        let max_deposit: vector<u64> = vector[1000 * ONE_SUPRA, 1000 * ONE_SUPRA, 1000
            * ONE_SUPRA];
        let lockin_duration: vector<u64> = vector[6000, 6000, 6000];
        let slot_start_time: vector<u64> = vector[100, 100, 100];
        let slot_return_percentage: vector<u64> = vector[2000, 1500, 1000];
        let slot_deposit_duration: vector<u64> = vector[600, 1200, 1800];
        let min_deposit_per_txn: vector<u64> = vector[10 * ONE_SUPRA, 10 * ONE_SUPRA, 10
            * ONE_SUPRA];
        let slot_addresses =
            create_multiple_slots(
                creator,
                max_deposit,
                lockin_duration,
                slot_start_time,
                slot_return_percentage,
                slot_deposit_duration,
                min_deposit_per_txn
            );
        slot_addresses
    }


    #[
    test(
        supra_framework = @supra_framework,
        creator = @0x123,
    )
    ]
    #[expected_failure(abort_code = 0x7000d, location = Self)]
    fun test_create_slots_lockin_duration_less_than_deposit_duration(
        supra_framework: &signer,
        creator: &signer,
    ): vector<address> {
        timestamp::set_time_has_started_for_testing(supra_framework);
        let (burn_cap, min_cap) = supra_coin::initialize_for_test(supra_framework);
        supra_account::deposit_coins<SupraCoin>(
            signer::address_of(creator),
            coin::mint<SupraCoin>(10000 * ONE_SUPRA, &min_cap)
        );

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(min_cap);

        let max_deposit: vector<u64> = vector[1000 * ONE_SUPRA, 1000 * ONE_SUPRA, 1000
            * ONE_SUPRA];
        let lockin_duration: vector<u64> = vector[600, 600, 600];
        let slot_start_time: vector<u64> = vector[100, 100, 100];
        let slot_return_percentage: vector<u64> = vector[2000, 1500, 1000];
        let slot_deposit_duration: vector<u64> = vector[600, 1200, 1800];
        let min_deposit_per_txn: vector<u64> = vector[10 * ONE_SUPRA, 10 * ONE_SUPRA, 10
            * ONE_SUPRA];
        let slot_addresses =
            create_multiple_slots(
                creator,
                max_deposit,
                lockin_duration,
                slot_start_time,
                slot_return_percentage,
                slot_deposit_duration,
                min_deposit_per_txn
            );
        slot_addresses
    }

    #[
    test(
        supra_framework = @supra_framework,
        creator = @0x123,
        first_user = @0x12345,
        second_user = @0x23456
    )
    ]
    fun test_lockin(
        supra_framework: &signer,
        creator: &signer,
        first_user: &signer,
        second_user: &signer
    ) acquires SlotConfig {
        let slot_addresses =
            create_slots_and_add_funds(
                supra_framework,
                creator,
                first_user,
                second_user
            );

        timestamp::fast_forward_seconds(100);
        vector::for_each_ref(
            &slot_addresses,
            |slot| {
                lockin<SupraCoin>(first_user, *slot, 10 * ONE_SUPRA);
                lockin<SupraCoin>(second_user, *slot, 20 * ONE_SUPRA);
                assert!(
                    coin::balance<SupraCoin>(*slot) == 30 * ONE_SUPRA,
                    error::invalid_state(0)
                );
            }
        );

        let slot_funds = slot_deposits<SupraCoin>(slot_addresses);
        vector::for_each_ref(
            &slot_funds,
            |fund| {
                assert!(*fund == 30 * ONE_SUPRA, error::invalid_state(1));
            }
        );
    }

    #[
    test(
        supra_framework = @supra_framework,
        creator = @0x123,
        first_user = @0x12345,
        second_user = @0x23456
    )
    ]
    #[expected_failure(abort_code = 0x5000c, location = Self)]
    fun test_fail_lockin_early_deposit(
        supra_framework: &signer,
        creator: &signer,
        first_user: &signer,
        second_user: &signer
    ) acquires SlotConfig {
        let slot_addresses =
            create_slots_and_add_funds(
                supra_framework,
                creator,
                first_user,
                second_user
            );

        timestamp::fast_forward_seconds(99);
        vector::for_each_ref(
            &slot_addresses,
            |slot| {
                lockin<SupraCoin>(first_user, *slot, 10 * ONE_SUPRA);
                lockin<SupraCoin>(second_user, *slot, 20 * ONE_SUPRA);
                assert!(
                    coin::balance<SupraCoin>(*slot) == 30 * ONE_SUPRA,
                    error::invalid_state(0)
                );
            }
        );

        let slot_funds = slot_deposits<SupraCoin>(slot_addresses);
        vector::for_each_ref(
            &slot_funds,
            |fund| {
                assert!(*fund == 30 * ONE_SUPRA, error::invalid_state(1));
            }
        );
    }

    #[
    test(
        supra_framework = @supra_framework,
        creator = @0x123,
        first_user = @0x12345,
        second_user = @0x23456
    )
    ]
    #[expected_failure(abort_code = 0x7000e, location = Self)]
    fun test_fail_excess_reward_deposit(
        supra_framework: &signer,
        creator: &signer,
        first_user: &signer,
        second_user: &signer
    ) acquires SlotConfig {
        let slot_addresses =
            create_slots_and_add_funds(
                supra_framework,
                creator,
                first_user,
                second_user
            );
        let reward_amount: vector<u64> = vector::empty<u64>();
        let reward: u64;

        timestamp::fast_forward_seconds(101);
        vector::for_each_ref(
            &slot_addresses,
            |slot| {
                lockin<SupraCoin>(first_user, *slot, 10 * ONE_SUPRA);
                lockin<SupraCoin>(second_user, *slot, 20 * ONE_SUPRA);
                assert!(
                    coin::balance<SupraCoin>(*slot) == 30 * ONE_SUPRA,
                    error::invalid_state(0)
                );

                let slot_details = borrow_global_mut<SlotConfig<SupraCoin>>(*slot);
                reward = (slot_details.current_deposit * slot_details.return_percentage / (REWARD_DECIMALS * REWARD_PERCENTAGE_DENOMINATOR)) + 1;
                vector::push_back(&mut reward_amount, reward);
            }
        );

        assert!(
            coin::balance<SupraCoin>(signer::address_of(first_user)) == 9970 * ONE_SUPRA,
            error::invalid_state(0)
        );
        assert!(
            coin::balance<SupraCoin>(signer::address_of(second_user)) == 9940 * ONE_SUPRA,
            error::invalid_state(0)
        );


        vector::zip_ref(&slot_addresses, &reward_amount, |slot_address, reward|{
            let slot_fund = slot_deposits<SupraCoin>(vector[*slot_address]);
            assert!(*vector::borrow(&slot_fund, 0) == 30 * ONE_SUPRA, error::invalid_state(1));
            fund_reward<SupraCoin>(creator, *slot_address, *reward + 1);
        });
    }

    #[
    test(
        supra_framework = @supra_framework,
        creator = @0x123,
        first_user = @0x12345,
        second_user = @0x23456
    )
    ]
    #[expected_failure(abort_code = 0x50003, location = Self)]
    fun test_fail_lockin_late_deposit(
        supra_framework: &signer,
        creator: &signer,
        first_user: &signer,
        second_user: &signer
    ) acquires SlotConfig {
        let slot_addresses =
            create_slots_and_add_funds(
                supra_framework,
                creator,
                first_user,
                second_user
            );

        timestamp::fast_forward_seconds(1801);
        vector::for_each_ref(
            &slot_addresses,
            |slot| {
                lockin<SupraCoin>(first_user, *slot, 10 * ONE_SUPRA);
                lockin<SupraCoin>(first_user, *slot, 20 * ONE_SUPRA);
                assert!(
                    coin::balance<SupraCoin>(*slot) == 30 * ONE_SUPRA,
                    error::invalid_state(0)
                );
            }
        );

        let slot_funds = slot_deposits<SupraCoin>(slot_addresses);
        vector::for_each_ref(
            &slot_funds,
            |fund| {
                assert!(*fund == 30 * ONE_SUPRA, error::invalid_state(1));
            }
        );
    }

    #[
    test(
        supra_framework = @supra_framework,
        creator = @0x123,
        first_user = @0x12345,
        second_user = @0x23456
    )
    ]
    #[expected_failure(abort_code = 0x50004, location = Self)]
    fun test_fail_lockin_lowdeposit(
        supra_framework: &signer,
        creator: &signer,
        first_user: &signer,
        second_user: &signer
    ) acquires SlotConfig {
        let slot_addresses =
            create_slots_and_add_funds(
                supra_framework,
                creator,
                first_user,
                second_user
            );

        timestamp::fast_forward_seconds(1801);
        vector::for_each_ref(
            &slot_addresses,
            |slot| {
                lockin<SupraCoin>(first_user, *slot, 1 * ONE_SUPRA);
                lockin<SupraCoin>(first_user, *slot, 2 * ONE_SUPRA);
                assert!(
                    coin::balance<SupraCoin>(*slot) == 30 * ONE_SUPRA,
                    error::invalid_state(0)
                );
            }
        );

        let slot_funds = slot_deposits<SupraCoin>(slot_addresses);
        vector::for_each_ref(
            &slot_funds,
            |fund| {
                assert!(*fund == 3 * ONE_SUPRA, error::invalid_state(1));
            }
        );
    }

    #[
    test(
        supra_framework = @supra_framework,
        creator = @0x123,
        first_user = @0x12345,
        second_user = @0x23456
    )
    ]
    #[expected_failure(abort_code = 0x50005, location = Self)]
    fun test_fail_lockin_high_deposit(
        supra_framework: &signer,
        creator: &signer,
        first_user: &signer,
        second_user: &signer
    ) acquires SlotConfig {
        let slot_addresses =
            create_slots_and_add_funds(
                supra_framework,
                creator,
                first_user,
                second_user
            );

        timestamp::fast_forward_seconds(1801);
        vector::for_each_ref(
            &slot_addresses,
            |slot| {
                lockin<SupraCoin>(first_user, *slot, 1000 * ONE_SUPRA);
                lockin<SupraCoin>(first_user, *slot, 10 * ONE_SUPRA);
                assert!(
                    coin::balance<SupraCoin>(*slot) == 30 * ONE_SUPRA,
                    error::invalid_state(0)
                );
            }
        );

        let slot_funds = slot_deposits<SupraCoin>(slot_addresses);
        vector::for_each_ref(
            &slot_funds,
            |fund| {
                assert!(
                    *fund == 1010 * ONE_SUPRA,
                    error::invalid_state(1)
                );
            }
        );
    }

    #[
    test(
        supra_framework = @supra_framework,
        creator = @0x123,
        first_user = @0x12345,
        second_user = @0x23456
    )
    ]
    #[expected_failure(abort_code = 0x5000b, location = Self)]
    fun test_fail_lockin_quants(
        supra_framework: &signer,
        creator: &signer,
        first_user: &signer,
        second_user: &signer
    ) acquires SlotConfig {
        let slot_addresses =
            create_slots_and_add_funds(
                supra_framework,
                creator,
                first_user,
                second_user
            );

        timestamp::fast_forward_seconds(1801);
        vector::for_each_ref(
            &slot_addresses,
            |slot| {
                lockin<SupraCoin>(first_user, *slot, 100000);
                lockin<SupraCoin>(first_user, *slot, 200000);
                assert!(
                    coin::balance<SupraCoin>(*slot) == 30 * ONE_SUPRA,
                    error::invalid_state(0)
                );
            }
        );

        let slot_funds = slot_deposits<SupraCoin>(slot_addresses);
        vector::for_each_ref(
            &slot_funds,
            |fund| {
                assert!(*fund == 300000, error::invalid_state(1));
            }
        );
    }

    #[
    test(
        supra_framework = @supra_framework,
        creator = @0x123,
        first_user = @0x12345,
        second_user = @0x23456
    )
    ]
    fun test_end_to_end_success(
        supra_framework: &signer,
        creator: &signer,
        first_user: &signer,
        second_user: &signer
    ) acquires SlotConfig {
        let slot_addresses =
            create_slots_and_add_funds(
                supra_framework,
                creator,
                first_user,
                second_user
            );

        let slot_0_address = *vector::borrow(&slot_addresses, 0);
        let slot_1_address = *vector::borrow(&slot_addresses, 1);
        let slot_2_address = *vector::borrow(&slot_addresses, 2);
        let creator_address = signer::address_of(creator);
        let first_address = signer::address_of(first_user);
        let second_address = signer::address_of(second_user);
        // Add first slot at start time minimum amount
        timestamp::fast_forward_seconds(100);
        lockin<SupraCoin>(creator, slot_2_address, 10 * ONE_SUPRA);
        assert!(
            coin::balance<SupraCoin>(slot_2_address) == 10 * ONE_SUPRA,
            9
        );
        assert!(
            coin::balance<SupraCoin>(creator_address)
                == 10000 * ONE_SUPRA - 10 * ONE_SUPRA,
            10
        );
        let user_deposits =
            user_deposits<SupraCoin>(creator_address, vector[slot_2_address]);
        let user_sum = vector::foldr(
            user_deposits,
            0,
            |elem, running_sum| {
                running_sum = running_sum + elem;
                running_sum
            }
        );
        assert!(user_sum == 10 * ONE_SUPRA, user_sum);


        // Add second slot at end time maximum amount
        timestamp::fast_forward_seconds(600);
        lockin<SupraCoin>(first_user, slot_1_address, 90 * ONE_SUPRA);
        lockin<SupraCoin>(first_user, slot_1_address, 900 * ONE_SUPRA);
        lockin<SupraCoin>(creator, slot_1_address, 10 * ONE_SUPRA);
        assert!(
            coin::balance<SupraCoin>(slot_1_address) == 1000 * ONE_SUPRA,
            9
        );
        assert!(
            coin::balance<SupraCoin>(creator_address) == 9980 * ONE_SUPRA,
            10
        );
        assert!(
            coin::balance<SupraCoin>(first_address) == 9010 * ONE_SUPRA,
            10
        );
        let user_deposits =
            user_deposits<SupraCoin>(
                creator_address, vector[slot_1_address, slot_2_address]
            );
        let user_sum = vector::foldr(
            user_deposits,
            0,
            |elem, running_sum| {
                running_sum = running_sum + elem;
                running_sum
            }
        );
        assert!(user_sum == 20 * ONE_SUPRA, user_sum);
        // Add third slot at end time maximum amount
        timestamp::fast_forward_seconds(600);
        lockin<SupraCoin>(second_user, slot_0_address, 490 * ONE_SUPRA);
        lockin<SupraCoin>(first_user, slot_0_address, 500 * ONE_SUPRA);
        lockin<SupraCoin>(creator, slot_0_address, 10 * ONE_SUPRA);
        assert!(
            coin::balance<SupraCoin>(slot_0_address) == 1000 * ONE_SUPRA,
            9
        );
        assert!(
            coin::balance<SupraCoin>(second_address) == 9510 * ONE_SUPRA,
            10
        );
        assert!(
            coin::balance<SupraCoin>(first_address) == 8510 * ONE_SUPRA,
            10
        );
        assert!(
            coin::balance<SupraCoin>(creator_address) == 9970 * ONE_SUPRA,
            10
        );

        let user_deposits = user_deposits<SupraCoin>(creator_address, slot_addresses);
        let user_sum = vector::foldr(
            user_deposits,
            0,
            |elem, running_sum| {
                running_sum = running_sum + elem;
                running_sum
            }
        );
        assert!(user_sum == 30 * ONE_SUPRA, user_sum);

        let user_deposits =
            user_deposits<SupraCoin>(first_address, vector[slot_1_address, slot_0_address]);
        let user_sum = vector::foldr(
            user_deposits,
            0,
            |elem, running_sum| {
                running_sum = running_sum + elem;
                running_sum
            }
        );
        assert!(user_sum == 1490 * ONE_SUPRA, user_sum);


        // Fast forward to maturity time of slot 2
        timestamp::fast_forward_seconds(4801);
        fund_reward<SupraCoin>(creator, slot_2_address, 2 * ONE_SUPRA);
        claim<SupraCoin>(creator_address, slot_2_address);
        assert!(
            coin::balance<SupraCoin>(creator_address) == 9980 * ONE_SUPRA,
            10
        );

        // add 15% to slot 1

        fund_reward<SupraCoin>(creator, slot_1_address, 150 * ONE_SUPRA);
        timestamp::fast_forward_seconds(600);
        claim<SupraCoin>(creator_address, slot_1_address);
        claim<SupraCoin>(first_address, slot_1_address);
        let creator_balance = coin::balance<SupraCoin>(creator_address);
        let first_balance = coin::balance<SupraCoin>(first_address);
        assert!(creator_balance == 984150000000, creator_balance);
        assert!(first_balance == 964850000000, first_balance);

        // add 10% to slot 0
        fund_reward<SupraCoin>(creator, slot_0_address, 100 * ONE_SUPRA);

        timestamp::fast_forward_seconds(600);
        claim<SupraCoin>(creator_address, slot_0_address);
        claim<SupraCoin>(first_address, slot_0_address);
        claim<SupraCoin>(second_address, slot_0_address);

        let balance = coin::balance<SupraCoin>(creator_address);
        assert!(balance == 975250000000, balance);

        let balance = coin::balance<SupraCoin>(first_address);
        assert!(balance == 1019850000000, balance);
        let balance = coin::balance<SupraCoin>(second_address);
        assert!(balance == 10049 * ONE_SUPRA, balance);
    }
}

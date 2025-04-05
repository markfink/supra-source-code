/// The global config for dexlyn_swap: fees and manager accounts (admins).
module dexlyn_swap::global_config {
    use std::signer;
    use aptos_std::event;

    use supra_framework::multisig_account;
    use supra_framework::object;

    use dexlyn_swap::curves;

    friend dexlyn_swap::liquidity_pool;

    // Error codes.

    /// When config doesn't exists.
    const ERR_CONFIG_DOES_NOT_EXIST: u64 = 300;

    /// When user is not admin
    const ERR_NOT_ADMIN: u64 = 301;

    /// When invalid fee amount
    const ERR_INVALID_FEE: u64 = 302;

    /// Unreachable, is a bug if thrown
    const ERR_UNREACHABLE: u64 = 303;

    /// When the account is not a multisig
    const EINVALID_MULTISIG_ACCOUNT: u64 = 304;

    // Constants.

    /// Minimum value of fee, 0.01%
    const MIN_FEE: u64 = 1;

    /// Maximum value of fee, 1%
    const MAX_FEE: u64 = 100;

    /// Minimum value of dao fee, 0%
    const MIN_DAO_FEE: u64 = 0;

    /// Maximum value of dao fee, 100%
    const MAX_DAO_FEE: u64 = 100;

    /// Defined Storage seed that are used for creating object
    const SEED_GLOBAL_CONFIG: vector<u8> = b"global_config::GlobalConfig";

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    struct ObjectController has key {
        transfer_ref: object::TransferRef,
        extend_ref: object::ExtendRef,
    }

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    /// The global configuration (fees and admin accounts).
    struct GlobalConfig has key {
        dao_admin_address: address,
        emergency_admin_address: address,
        fee_admin_address: address,
        default_uncorrelated_fee: u64,
        default_stable_fee: u64,
        default_dao_fee: u64,
    }


    /// Event struct when fee updates.
    struct UpdateDefaultFeeEvent has drop, store {
        fee: u64,
    }

    #[event]
    /// Event struct when Uncorrelated fee updates.
    struct UpdateDefaultUncorrelatedFeeEvent has drop, store {
        fee: u64,
    }

    #[event]
    /// Event struct when Stable fee updates.
    struct UpdateDefaultStableFeeEvent has drop, store {
        fee: u64,
    }

    #[event]
    /// Event struct when Dao fee updates.
    struct UpdateDefaultDaoFeeEvent has drop, store {
        fee: u64,
    }

    /// Initializes admin contracts when initializing the liquidity pool.
    public(friend) fun initialize(dexlyn_swap_admin: &signer) {
        assert!(signer::address_of(dexlyn_swap_admin) == @dexlyn_swap, ERR_UNREACHABLE);

        let cons_ref = object::create_named_object(dexlyn_swap_admin, SEED_GLOBAL_CONFIG);
        let object_signer = object::generate_signer(&cons_ref);

        // All the admin addresses should be an multisig
        assert_multisig(@dao_admin);
        assert_multisig(@emergency_admin);
        assert_multisig(@fee_admin);

        move_to(&object_signer, GlobalConfig {
            dao_admin_address: @dao_admin,
            emergency_admin_address: @emergency_admin,
            fee_admin_address: @fee_admin,
            default_uncorrelated_fee: 30, // 0.3%
            default_stable_fee: 4, // 0.04%
            default_dao_fee: 33, // 33%
        });
        move_to(
            &object_signer,
            ObjectController {
                transfer_ref: object::generate_transfer_ref(&cons_ref),
                extend_ref: object::generate_extend_ref(&cons_ref)
            }
        );
    }

    /// Get DAO admin address.
    public fun get_dao_admin(): address acquires GlobalConfig {
        let global_config_addr = get_global_config_addr();
        assert!(exists<GlobalConfig>(global_config_addr), ERR_CONFIG_DOES_NOT_EXIST);

        let config = borrow_global<GlobalConfig>(global_config_addr);
        config.dao_admin_address
    }

    /// Internal function - to check given address is valid multisig or not
    fun assert_multisig(multisig_address: address) {
        assert!(
            multisig_account::num_signatures_required(multisig_address) >= 2,
            EINVALID_MULTISIG_ACCOUNT
        );
    }

    /// Set DAO admin account.
    public entry fun set_dao_admin(dao_admin: &signer, new_addr: address) acquires GlobalConfig {
        assert_multisig(new_addr);
        let global_config_addr = get_global_config_addr();
        assert!(exists<GlobalConfig>(global_config_addr), ERR_CONFIG_DOES_NOT_EXIST);

        let config = borrow_global_mut<GlobalConfig>(global_config_addr);
        assert!(config.dao_admin_address == signer::address_of(dao_admin), ERR_NOT_ADMIN);

        config.dao_admin_address = new_addr;
    }

    /// Get emergency admin address.
    public fun get_emergency_admin(): address acquires GlobalConfig {
        let global_config_addr = get_global_config_addr();
        assert!(exists<GlobalConfig>(global_config_addr), ERR_CONFIG_DOES_NOT_EXIST);

        let config = borrow_global<GlobalConfig>(global_config_addr);
        config.emergency_admin_address
    }

    /// Set emergency admin account.
    public entry fun set_emergency_admin(emergency_admin: &signer, new_addr: address) acquires GlobalConfig {
        assert_multisig(new_addr);
        let global_config_addr = get_global_config_addr();
        assert!(exists<GlobalConfig>(global_config_addr), ERR_CONFIG_DOES_NOT_EXIST);

        let config = borrow_global_mut<GlobalConfig>(global_config_addr);
        assert!(config.emergency_admin_address == signer::address_of(emergency_admin), ERR_NOT_ADMIN);

        config.emergency_admin_address = new_addr;
    }

    /// Get fee admin address.
    public fun get_fee_admin(): address acquires GlobalConfig {
        let global_config_addr = get_global_config_addr();
        assert!(exists<GlobalConfig>(global_config_addr), ERR_CONFIG_DOES_NOT_EXIST);

        let config = borrow_global<GlobalConfig>(global_config_addr);
        config.fee_admin_address
    }

    /// Set fee admin account.
    public entry fun set_fee_admin(fee_admin: &signer, new_addr: address) acquires GlobalConfig {
        assert_multisig(new_addr);
        let global_config_addr = get_global_config_addr();
        assert!(exists<GlobalConfig>(global_config_addr), ERR_CONFIG_DOES_NOT_EXIST);

        let config = borrow_global_mut<GlobalConfig>(global_config_addr);
        assert!(config.fee_admin_address == signer::address_of(fee_admin), ERR_NOT_ADMIN);

        config.fee_admin_address = new_addr;
    }

    /// Get default fee for pool.
    /// IMPORTANT: use functions in Liquidity Pool module as pool fees could be different from default ones.
    public fun get_default_fee<Curve>(): u64 acquires GlobalConfig {
        curves::assert_valid_curve<Curve>();
        let global_config_addr = get_global_config_addr();
        assert!(exists<GlobalConfig>(global_config_addr), ERR_CONFIG_DOES_NOT_EXIST);

        let config = borrow_global<GlobalConfig>(global_config_addr);
        if (curves::is_stable<Curve>()) {
            config.default_stable_fee
        } else if (curves::is_uncorrelated<Curve>()) {
            config.default_uncorrelated_fee
        } else {
            abort ERR_UNREACHABLE
        }
    }

    /// Set new default fee.
    public entry fun set_default_fee<Curve>(fee_admin: &signer, default_fee: u64) acquires GlobalConfig {
        curves::assert_valid_curve<Curve>();
        let global_config_addr = get_global_config_addr();
        assert!(exists<GlobalConfig>(global_config_addr), ERR_CONFIG_DOES_NOT_EXIST);

        let config = borrow_global_mut<GlobalConfig>(global_config_addr);
        assert!(config.fee_admin_address == signer::address_of(fee_admin), ERR_NOT_ADMIN);

        assert_valid_fee(default_fee);


        if (curves::is_stable<Curve>()) {
            config.default_stable_fee = default_fee;
            event::emit(UpdateDefaultStableFeeEvent { fee: default_fee });
        } else if (curves::is_uncorrelated<Curve>()) {
            config.default_uncorrelated_fee = default_fee;
            event::emit(UpdateDefaultUncorrelatedFeeEvent { fee: default_fee });
        } else {
            abort ERR_UNREACHABLE
        };
    }

    /// Get default DAO fee.
    public fun get_default_dao_fee(): u64 acquires GlobalConfig {
        let global_config_addr = get_global_config_addr();
        assert!(exists<GlobalConfig>(global_config_addr), ERR_CONFIG_DOES_NOT_EXIST);

        let config = borrow_global<GlobalConfig>(global_config_addr);
        config.default_dao_fee
    }

    /// Set default DAO fee.
    public entry fun set_default_dao_fee(fee_admin: &signer, default_fee: u64) acquires GlobalConfig {
        let global_config_addr = get_global_config_addr();
        assert!(exists<GlobalConfig>(global_config_addr), ERR_CONFIG_DOES_NOT_EXIST);

        let config = borrow_global_mut<GlobalConfig>(global_config_addr);
        assert!(config.fee_admin_address == signer::address_of(fee_admin), ERR_NOT_ADMIN);

        assert_valid_dao_fee(default_fee);

        config.default_dao_fee = default_fee;

        event::emit(UpdateDefaultDaoFeeEvent { fee: default_fee });
    }

    #[view]
    public fun get_global_config_addr(): address {
        object::create_object_address(&@dexlyn_swap, SEED_GLOBAL_CONFIG)
    }


    /// Aborts if fee is valid.
    public fun assert_valid_fee(fee: u64) {
        assert!(MIN_FEE <= fee && fee <= MAX_FEE, ERR_INVALID_FEE);
    }

    /// Aborts if dao fee is valid.
    public fun assert_valid_dao_fee(dao_fee: u64) {
        assert!(MIN_DAO_FEE <= dao_fee && dao_fee <= MAX_DAO_FEE, ERR_INVALID_FEE);
    }

    #[test_only]
    public fun initialize_for_test() {
        let dexlyn_swap_admin = supra_framework::account::create_account_for_test(@dexlyn_swap);
        initialize(&dexlyn_swap_admin);
    }
}

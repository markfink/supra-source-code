/// The module allows for emergency stop dexlyn_swap operations.
module dexlyn_swap::emergency {
    use std::signer;

    use supra_framework::object;

    use dexlyn_swap::global_config;

    friend dexlyn_swap::liquidity_pool;

    // Error codes.
    /// When the wrong account attempted to create an emergency resource.
    const ERR_NO_PERMISSIONS: u64 = 4000;

    /// When attempted to execute operation during an emergency.
    const ERR_EMERGENCY: u64 = 4001;

    /// When emergency functional disabled.
    const ERR_DISABLED: u64 = 4002;

    /// When attempted to resume, but we are not in an emergency state.
    const ERR_NOT_EMERGENCY: u64 = 4003;

    /// Should never occur.
    const ERR_UNREACHABLE: u64 = 4004;

    /// Emergency Account seed.
    const SEED_EMERGENCY_ACCOUNT: vector<u8> = b"emergency_account_seed";

    struct IsEmergency has key {}

    struct IsDisabled has key {}

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    struct EmergencyAccountController has key {
        transfer_ref: object::TransferRef,
        extend_ref: object::ExtendRef,
    }

    public(friend) fun initialize(dexlyn_swap_admin: &signer) {
        assert!(signer::address_of(dexlyn_swap_admin) == @dexlyn_swap, ERR_UNREACHABLE);

        let cons_ref = object::create_named_object(dexlyn_swap_admin, SEED_EMERGENCY_ACCOUNT);
        let extend_ref = object::generate_extend_ref(&cons_ref);
        let transfer_ref = object::generate_transfer_ref(&cons_ref);
        let object_signer = object::generate_signer(&cons_ref);
        move_to(&object_signer, EmergencyAccountController { transfer_ref, extend_ref });
    }

    /// Pauses all operations.
    public entry fun pause(account: &signer) acquires EmergencyAccountController {
        assert!(!is_disabled(), ERR_DISABLED);
        assert_no_emergency();

        assert!(signer::address_of(account) == global_config::get_emergency_admin(), ERR_NO_PERMISSIONS);

        let emergency_account_cap =
            borrow_global<EmergencyAccountController>(get_emergency_account_addr());
        let emergency_account = object::generate_signer_for_extending(&emergency_account_cap.extend_ref);
        move_to(&emergency_account, IsEmergency {});
    }

    /// Resumes all operations.
    public entry fun resume(account: &signer) acquires IsEmergency {
        assert!(!is_disabled(), ERR_DISABLED);

        let account_addr = signer::address_of(account);
        assert!(account_addr == global_config::get_emergency_admin(), ERR_NO_PERMISSIONS);
        assert!(is_emergency(), ERR_NOT_EMERGENCY);

        let IsEmergency {} = move_from<IsEmergency>(get_emergency_account_addr());
    }

    /// Get if it's paused or not.
    public fun is_emergency(): bool {
        exists<IsEmergency>(get_emergency_account_addr())
    }

    /// Would abort if currently paused.
    public fun assert_no_emergency() {
        assert!(!is_emergency(), ERR_EMERGENCY);
    }

    /// Get if it's disabled or not.
    public fun is_disabled(): bool {
        exists<IsDisabled>(get_emergency_account_addr())
    }

    /// Disable condition forever.
    public entry fun disable_forever(account: &signer) acquires EmergencyAccountController {
        assert!(!is_disabled(), ERR_DISABLED);
        assert!(signer::address_of(account) == global_config::get_emergency_admin(), ERR_NO_PERMISSIONS);

        let emergency_account_cap =
            borrow_global<EmergencyAccountController>(get_emergency_account_addr());
        let emergency_account = object::generate_signer_for_extending(&emergency_account_cap.extend_ref);
        move_to(&emergency_account, IsDisabled {});
    }

    #[view]
    public fun get_emergency_account_addr(): address {
        object::create_object_address(&@dexlyn_swap, SEED_EMERGENCY_ACCOUNT)
    }
}

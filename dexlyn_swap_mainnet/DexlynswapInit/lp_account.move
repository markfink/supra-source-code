/// The module used to create user resource account for dexlyn_swap and deploy LP coins under that account.
module dexlyn_swap::lp_account {
    use std::signer;

    use supra_framework::account::{Self, SignerCapability};

    /// When called from wrong account.
    const ERR_NOT_ENOUGH_PERMISSIONS: u64 = 1701;

    /// dexlyn account see
    const DEXLYN_ACCOUNT_SEED: vector<u8> = b"dexlyn_account_seed";

    /// Temporary storage for user resource account signer capability.
    struct CapabilityStorage has key { signer_cap: SignerCapability }

    /// Creates new resource account for dexlyn_swap, puts signer capability into storage
    /// and deploys LP coin type.
    /// Can be executed only from dexlyn_swap account.
    public entry fun initialize_lp_account(
        dexlyn_swap_admin: &signer,
        lp_coin_metadata_serialized: vector<u8>,
        lp_coin_code: vector<u8>
    ) {
        assert!(signer::address_of(dexlyn_swap_admin) == @dexlyn_swap, ERR_NOT_ENOUGH_PERMISSIONS);

        let (lp_acc, signer_cap) =
            account::create_resource_account(dexlyn_swap_admin, DEXLYN_ACCOUNT_SEED);
        supra_framework::code::publish_package_txn(
            &lp_acc,
            lp_coin_metadata_serialized,
            vector[lp_coin_code]
        );
        move_to(dexlyn_swap_admin, CapabilityStorage { signer_cap });
    }

    /// Destroys temporary storage for resource account signer capability and returns signer capability.
    /// It needs for initialization of dexlyn_swap.
    public fun retrieve_signer_cap(dexlyn_swap_admin: &signer): SignerCapability acquires CapabilityStorage {
        assert!(signer::address_of(dexlyn_swap_admin) == @dexlyn_swap, ERR_NOT_ENOUGH_PERMISSIONS);
        let CapabilityStorage { signer_cap } =
            move_from<CapabilityStorage>(signer::address_of(dexlyn_swap_admin));
        signer_cap
    }

    #[test(supra = @0x0dc694898dff98a1b0447e0992d0413e123ea80da1021d464a4fbaf0265870d8)]
    public fun get_lp_token_address(supra: &signer) {
        let reource_addr = account::create_resource_address(&signer::address_of(supra), DEXLYN_ACCOUNT_SEED);
        std::debug::print(&reource_addr)
    }
}

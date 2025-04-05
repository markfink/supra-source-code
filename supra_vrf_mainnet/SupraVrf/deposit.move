module supra_addr::deposit {
    use aptos_std::table;

    use std::error;
    use std::vector;
    use std::signer;

    use supra_framework::event::emit;
    use supra_framework::coin;
    use supra_framework::multisig_account;
    use supra_framework::object;
    use supra_framework::supra_coin::SupraCoin;
    use supra_framework::timestamp;

    use supra_addr::supra_util;
    friend supra_addr::supra_vrf;

    /// Defined Deposit BalanceManagement seeds that are used for creating resources
    const SEED_BALANCE: vector<u8> = b"deposit::BalanceManagement";
    /// Defined Deposit DepositManagement seeds that are used for creating object
    const SEED_DEPOSIT_MANAGEMENT: vector<u8> = b"deposit::DepositManagement";
    /// This is a default min_balance_limit of supra at time of deployment
    const MIN_BALANCE_LIMIT: u64 = 100000000;
    /// 180 days into second
    const SUBSCRIPTION_DURATION: u64 = 15552000;

    /// Client Address does not exist
    const ECLIENT_NOT_EXIST: u64 = 1;
    /// Client Address already exist
    const ECLIENT_ALREADY_EXIST: u64 = 2;
    /// Not enough Aptos Coin
    const ENOT_ENOUGH_BALANCE: u64 = 4;
    /// Contract Pause status
    const ECONTRACT_IS_PAUSED: u64 = 5;
    /// Checking client min_balance_limit with admin min_balance_limit_supra
    const EREQUIRED_MORE_MINIMUMBALANCELIMIT: u64 = 6;
    /// Amount can not be zero
    const EAMOUNT_CANNOT_BE_ZERO: u64 = 7;
    /// Contract is already whitelisted
    const ECONTRACT_ALREADY_EXISTS: u64 = 8;
    /// Contract is not whitelisted
    const ECONTRACT_DOES_NOT_EXIST: u64 = 9;
    /// Invalid new end time
    const EINVALID_END_DATE: u64 = 10;
    /// Balance should be at least the minimum balance configured by the client or Supra
    const EMIN_BALANCE: u64 = 11;
    /// Not enough coins to complete transaction or Invalid amount
    const EINVALID_AMOUNT: u64 = 12;
    /// Invalid Multisig account
    const EINVALID_MULTISIG_ACCOUNT: u64 = 14;
    /// Signer doesnt own the object
    const EINVALID_INDEX_PERMISSION: u64 = 15;

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    /// Deposit Management
    struct DepositManagement has key {
        is_paused: bool,
        min_balance_limit_supra: u64,
        whitelist_clients: table::Table<address, WhitelistClient>,
        subscription_period: table::Table<address, SubscriptionPeriod>
    }

    struct WhitelistClient has store, drop, copy {
        whitelisted_contract_address: vector<address>,
        min_balance_limit: u64
    }

    struct SubscriptionPeriod has store, drop, copy {
        start_date: u64,
        end_date: u64,
    }

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    struct ObjectController has key {
        transfer_ref: object::TransferRef,
        extend_ref: object::ExtendRef,
    }

    /// Balance Management
    struct BalanceManagement has key {
        total_coin: coin::Coin<SupraCoin>,
        client_balance: table::Table<address, u64>,
        supra_fund: u64,
    }

    #[event]
    /// Event emitted when client is whitelisted.
    struct ClientWhitelistedEvent has drop, store {
        client_address: address,
    }

    #[event]
    /// Event emitted when a contract is whitelisted.
    struct ContractWhitelistedEvent has drop, store {
        client_address: address,
        contract_address: address,
    }

    #[event]
    /// Event emitted when client is removed.
    struct ClientRemoveEvent has drop, store {
        client_address: address,
        client_balance: u64,
        client_transfer: bool,
    }

    #[event]
    /// Event emitted when contract is removed from whitelisted clients
    struct ContractsDeletedFromWhitelist has drop, store {
        client_address: address,
        contract_address: address,
    }

    #[event]
    /// Event emitted when supra is collected
    struct SupraCollected has drop, store {
        client_address: address,
        amount: u64,
        nonce: u64,
    }

    #[event]
    /// Event emitted when client is setting the minimum balance
    struct MinimumBalanceSet has drop, store {
        client_address: address,
        limit: u64,
    }

    /// It's been used to return client balance info
    struct ClientBalanceInfo has drop, copy {
        client_address: address,
        min_balance_limit: u64,
        balance: u64,
    }

    /// Internal - Create Module data resource
    fun create_deposit_management(owner_signer: &signer) {
        let cons_ref = object::create_named_object(owner_signer, SEED_DEPOSIT_MANAGEMENT);
        let object_signer = object::generate_signer(&cons_ref);
        move_to(&object_signer, DepositManagement {
            is_paused: false,
            whitelist_clients: table::new(),
            subscription_period: table::new(),
            min_balance_limit_supra: MIN_BALANCE_LIMIT,
        });
        move_to(&object_signer, ObjectController {
            transfer_ref: object::generate_transfer_ref(&cons_ref),
            extend_ref: object::generate_extend_ref(&cons_ref)
        });
    }

    /// Internal - Create Balance Management new resource account
    fun create_balance_management(owner_signer: &signer) {
        let cons_ref = object::create_named_object(owner_signer, SEED_BALANCE);
        let object_signer = object::generate_signer(&cons_ref);
        move_to(&object_signer, BalanceManagement {
            total_coin: coin::zero<SupraCoin>(),
            client_balance: table::new(),
            supra_fund: 0
        });
        move_to(&object_signer, ObjectController {
            transfer_ref: object::generate_transfer_ref(&cons_ref),
            extend_ref: object::generate_extend_ref(&cons_ref)
        });
    }

    /// Its Initial function which will be executed automatically while deployed packages
    fun init_module(owner_signer: &signer) {
        create_deposit_management(owner_signer);
        create_balance_management(owner_signer);
    }

    //#######################################################################################
    //    ::::::::::::::::::: SUPRA ADMIN - DEPOSIT CONFIGURATION :::::::::::::::::::::::::
    //#######################################################################################

    /// Friend function - to check contract is enabled
    /// EDIT: No more internal functions now; the friend module is now able to access it
    public(friend) fun ensure_contract_enabled(deposit_management_addr: address) acquires DepositManagement {
        let deposit_management = borrow_global<DepositManagement>(deposit_management_addr);
        assert!(!deposit_management.is_paused, error::permission_denied(ECONTRACT_IS_PAUSED));
    }

    /// Set min_balance_limit_supra
    public entry fun set_min_balance_limit_supra(
        sender: &signer,
        min_balance_limit_supra: u64
    ) acquires DepositManagement {
        let deposit_management_addr = get_deposit_management_object_address();
        supra_util::ensure_object_owner(object::address_to_object<DepositManagement>(deposit_management_addr), sender);
        assert!(min_balance_limit_supra != 0, error::invalid_argument(EAMOUNT_CANNOT_BE_ZERO));

        let deposit_management = borrow_global_mut<DepositManagement>(deposit_management_addr);
        deposit_management.min_balance_limit_supra = min_balance_limit_supra;
    }

    /// Set contract disabling by admin - True for disabling
    public entry fun set_contract_disabling(sender: &signer, pause: bool) acquires DepositManagement {
        let deposit_management_addr = get_deposit_management_object_address();
        supra_util::ensure_object_owner(object::address_to_object<DepositManagement>(deposit_management_addr), sender);

        let deposit_management = borrow_global_mut<DepositManagement>(deposit_management_addr);
        deposit_management.is_paused = pause;
    }

    /// Allows the supra admin to claim free node expenses from there supra_fund.
    public entry fun claim_free_node_expenses(
        sender: &signer,
        receiver_address: address,
        amount: u64
    ) acquires BalanceManagement {
        let balance_addr = get_balance_object_address();
        supra_util::ensure_object_owner(object::address_to_object<BalanceManagement>(balance_addr), sender);

        let balance_management = borrow_global_mut<BalanceManagement>(get_balance_object_address());

        ensure_enough_balance(balance_management.supra_fund, amount);
        balance_management.supra_fund = balance_management.supra_fund - amount;

        let extract_coin = coin::extract(&mut balance_management.total_coin, amount);
        coin::deposit<SupraCoin>(receiver_address, extract_coin);
    }

    /// Allows the supra_vrf's Module to collect funds in supra_fund from a client's balance.
    /// Basically it will use to collect callback transaction fee from client's wallet
    public(friend) fun collect_fund(
        client_address: address,
        withdraw_amount: u64,
        nonce: u64
    ) acquires BalanceManagement, DepositManagement {
        let deposit_management_addr = get_deposit_management_object_address();
        ensure_contract_enabled(deposit_management_addr);
        ensure_whitelisted_client(client_address, deposit_management_addr);

        let balance_management = borrow_global_mut<BalanceManagement>(get_balance_object_address());

        let client_balance_mut = table::borrow_mut(&mut balance_management.client_balance, client_address);
        let client_balance = *client_balance_mut;
        ensure_enough_balance(client_balance, withdraw_amount);

        *client_balance_mut = client_balance - withdraw_amount;
        balance_management.supra_fund = balance_management.supra_fund + withdraw_amount;

        if (*client_balance_mut == 0) {
            table::remove(&mut balance_management.client_balance, client_address);
        };

        // Emit and event that supra has collected transaction fee from client's balance
        emit(SupraCollected { client_address, amount: withdraw_amount, nonce });
    }

    entry fun migrate_to_multisig(owner_signer: &signer, multisig_address: address) acquires ObjectController {
        assert!(
            multisig_account::num_signatures_required(multisig_address) >= 2,
            error::invalid_state(EINVALID_MULTISIG_ACCOUNT)
        );
        let balance_addr = get_balance_object_address();
        supra_util::ensure_object_owner(object::address_to_object<ObjectController>(balance_addr), owner_signer);
        let object_controller = borrow_global<ObjectController>(balance_addr);
        let linear_transfer_ref = object::generate_linear_transfer_ref(&object_controller.transfer_ref);
        object::transfer_with_ref(linear_transfer_ref, multisig_address);
    }

    //#######################################################################################
    //    :::::::::::::::::::: SUPRA ADMIN - CLIENT WHITELIST ::::::::::::::::::::
    //#######################################################################################

    /// Internal function - to check client is whitelisted
    fun ensure_whitelisted_client(
        client_address: address,
        deposit_management_addr: address
    ) acquires DepositManagement {
        let deposit_management = borrow_global<DepositManagement>(deposit_management_addr);
        assert!(
            table::contains(&deposit_management.whitelist_clients, client_address),
            error::not_found(ECLIENT_NOT_EXIST)
        );
    }

    /// Internal function - to check client has enough balance
    fun ensure_enough_balance(balance: u64, amount: u64) {
        assert!(balance >= amount, error::permission_denied(ENOT_ENOUGH_BALANCE));
    }

    /// Add client wallet account address in to whitelist with default subsctiption duration
    public entry fun add_client_address(sender: &signer, client_address: address) acquires DepositManagement {
        add_client_address_with_subscription(sender, client_address, SUBSCRIPTION_DURATION);
    }

    /// Add client wallet account address in to whitelist with subscription duration
    public entry fun add_client_address_with_subscription(
        sender: &signer,
        client_address: address,
        subscription_duration: u64
    ) acquires DepositManagement {
        let deposit_management_addr = get_deposit_management_object_address();
        supra_util::ensure_object_owner(object::address_to_object<DepositManagement>(deposit_management_addr), sender);
        ensure_contract_enabled(deposit_management_addr);

        let deposit_management = borrow_global_mut<DepositManagement>(deposit_management_addr);
        assert!(
            !table::contains(&deposit_management.whitelist_clients, client_address),
            error::not_found(ECLIENT_ALREADY_EXIST)
        );

        // Add whitelist client default details
        let whitelist_client = WhitelistClient {
            whitelisted_contract_address: vector::empty<address>(),
            min_balance_limit: deposit_management.min_balance_limit_supra
        };
        table::add(&mut deposit_management.whitelist_clients, client_address, whitelist_client);

        // Add Whitelist client subscription info details
        let subscription_period = SubscriptionPeriod {
            start_date: timestamp::now_seconds(),
            end_date: timestamp::now_seconds() + subscription_duration
        };
        table::add(&mut deposit_management.subscription_period, client_address, subscription_period);

        // Emit an event that client address has been added in whitelist
        emit(ClientWhitelistedEvent { client_address });
    }

    /// Remove client wallet account address from whitelist
    public entry fun remove_client_address(
        sender: &signer,
        client_address: address,
        client_transfer: bool
    ) acquires BalanceManagement, DepositManagement {
        let deposit_management_addr = get_deposit_management_object_address();
        supra_util::ensure_object_owner(object::address_to_object<DepositManagement>(deposit_management_addr), sender);
        ensure_contract_enabled(deposit_management_addr);
        ensure_whitelisted_client(client_address, deposit_management_addr);

        // removing from whitelisted table
        let deposit_management = borrow_global_mut<DepositManagement>(deposit_management_addr);
        table::remove(&mut deposit_management.whitelist_clients, client_address);
        table::remove(&mut deposit_management.subscription_period, client_address);

        // Get client balance details
        let balance_management = borrow_global_mut<BalanceManagement>(get_balance_object_address());

        let client_balance = 0;
        // Check client has deposit balance
        if (table::contains(&balance_management.client_balance, client_address)) {
            client_balance = *table::borrow(&mut balance_management.client_balance, client_address);

            // Move client deposit fund into client wallet account if client_transfer is true or else move to supra_fund
            if (client_balance > 0 && client_transfer) {
                let extract_coin = coin::extract(&mut balance_management.total_coin, client_balance);
                coin::deposit<SupraCoin>(client_address, extract_coin);
            } else {
                balance_management.supra_fund = balance_management.supra_fund + client_balance;
            };
            table::remove(&mut balance_management.client_balance, client_address);
        };

        // Emit and event that admin has removed client wallet address from whitelist
        emit(ClientRemoveEvent { client_address, client_balance, client_transfer })
    }

    /// Remove all contract address from client's whitelist
    public entry fun remove_all_client_contracts(sender: &signer, client_address: address) acquires DepositManagement {
        let deposit_management_addr = get_deposit_management_object_address();
        supra_util::ensure_object_owner(object::address_to_object<DepositManagement>(deposit_management_addr), sender);
        ensure_contract_enabled(deposit_management_addr);
        ensure_whitelisted_client(client_address, deposit_management_addr);

        let deposit_management = borrow_global_mut<DepositManagement>(deposit_management_addr);
        let whitelist_clients = &mut deposit_management.whitelist_clients;
        let whitelist_client_ref = table::borrow_mut(whitelist_clients, client_address);

        whitelist_client_ref.whitelisted_contract_address = vector::empty<address>();
    }

    /// Update client subscription end date
    public entry fun update_client_subscription(
        sender: &signer,
        client_address: address,
        new_end_time: u64
    ) acquires DepositManagement {
        let deposit_management_addr = get_deposit_management_object_address();
        supra_util::ensure_object_owner(object::address_to_object<DepositManagement>(deposit_management_addr), sender);
        ensure_contract_enabled(deposit_management_addr);
        ensure_whitelisted_client(client_address, deposit_management_addr);

        // new end time should be at least more than 2 days
        assert!(new_end_time > (timestamp::now_seconds() + 172800), error::invalid_argument(EINVALID_END_DATE));

        let deposit_management = borrow_global_mut<DepositManagement>(deposit_management_addr);
        let subscription_period_ref = table::borrow_mut(&mut deposit_management.subscription_period, client_address);
        subscription_period_ref.end_date = new_end_time;
    }

    //#######################################################################################
    //    :::::::::::::::::::::: WHITELISTED CLIENT OPERATIONS ::::::::::::::::::::::::
    //#######################################################################################

    /// Sets the minimum balance limit
    public entry fun client_setting_minimum_balance(
        sender: &signer,
        min_balance_limit_client: u64
    ) acquires DepositManagement {
        let client_address = signer::address_of(sender);
        let deposit_management_addr = get_deposit_management_object_address();
        ensure_contract_enabled(deposit_management_addr);
        ensure_whitelisted_client(client_address, deposit_management_addr);

        let deposit_management = borrow_global_mut<DepositManagement>(deposit_management_addr);
        assert!(
            deposit_management.min_balance_limit_supra <= min_balance_limit_client,
            error::not_found(EREQUIRED_MORE_MINIMUMBALANCELIMIT)
        );

        let whitelist_clients = &mut deposit_management.whitelist_clients;
        let whitelist_client_ref = table::borrow_mut(whitelist_clients, client_address);
        whitelist_client_ref.min_balance_limit = min_balance_limit_client;

        // Emit an event that Client has set the Minimum balance
        emit(MinimumBalanceSet { client_address, limit: min_balance_limit_client });
    }

    /// client whitelisting the contract address
    public entry fun add_contract_to_whitelist(sender: &signer, contract_address: address) acquires DepositManagement {
        let client_address = signer::address_of(sender);
        let deposit_management_addr = get_deposit_management_object_address();
        ensure_contract_enabled(deposit_management_addr);
        ensure_whitelisted_client(client_address, deposit_management_addr);

        let deposit_management = borrow_global_mut<DepositManagement>(deposit_management_addr);
        let whitelist_clients = &mut deposit_management.whitelist_clients;
        let whitelist_client_ref = table::borrow_mut(whitelist_clients, client_address);

        assert!(
            !vector::contains(&whitelist_client_ref.whitelisted_contract_address, &contract_address),
            error::already_exists(ECONTRACT_ALREADY_EXISTS)
        );
        vector::push_back(&mut whitelist_client_ref.whitelisted_contract_address, contract_address);

        // emit event that one of the contract is whitelist
        emit(ContractWhitelistedEvent { client_address, contract_address });
    }

    /// Removing whitelisted contract address by client
    public entry fun remove_contract_from_whitelist(
        sender: &signer,
        contract_address: address
    ) acquires DepositManagement {
        let client_address = signer::address_of(sender);
        let deposit_management_addr = get_deposit_management_object_address();
        ensure_contract_enabled(deposit_management_addr);
        ensure_whitelisted_client(client_address, deposit_management_addr);

        let deposit_management = borrow_global_mut<DepositManagement>(deposit_management_addr);
        let whitelist_clients = &mut deposit_management.whitelist_clients;
        let whitelist_client_ref = table::borrow_mut(whitelist_clients, client_address);

        let (is_contract_exist, index) = vector::index_of(
            &whitelist_client_ref.whitelisted_contract_address,
            &contract_address
        );
        assert!(is_contract_exist, error::not_found(ECONTRACT_DOES_NOT_EXIST));
        //The vector::remove_value method is not supported by some chains (e.g., Movement).
        //Hence we obtain the index and then remove it from the vector using the vector::remove method.
        vector::remove(&mut whitelist_client_ref.whitelisted_contract_address, index); // Remove from whitelist

        // Emit an event that Contract address is removed from client's whitelist
        emit(ContractsDeletedFromWhitelist { client_address, contract_address });
    }

    /// Client deposit Aptos coin
    public entry fun deposit_fund(sender: &signer, deposit_amount: u64) acquires BalanceManagement, DepositManagement {
        let client_address = signer::address_of(sender);
        let deposit_management_addr = get_deposit_management_object_address();
        ensure_contract_enabled(deposit_management_addr);
        ensure_whitelisted_client(client_address, deposit_management_addr);

        assert!(
            deposit_amount > 0 && deposit_amount <= coin::balance<SupraCoin>(client_address),
            error::invalid_argument(EINVALID_AMOUNT)
        );

        let balance_management = borrow_global_mut<BalanceManagement>(get_balance_object_address());

        let client_min_balance = check_min_balance(client_address);

        if (!table::contains(&mut balance_management.client_balance, client_address)) {
            assert!(deposit_amount > client_min_balance, error::aborted(EMIN_BALANCE));
            table::add(&mut balance_management.client_balance, client_address, deposit_amount);
        } else {
            let client_balance_mut = table::borrow_mut(&mut balance_management.client_balance, client_address);
            let client_balance = *client_balance_mut;
            assert!((client_balance + deposit_amount) > client_min_balance, error::aborted(EMIN_BALANCE));
            *client_balance_mut = client_balance + deposit_amount;
        };

        let deposit_amount_coin = coin::withdraw<SupraCoin>(sender, deposit_amount);
        coin::merge(&mut balance_management.total_coin, deposit_amount_coin);
    }

    /// Client withdrawing Aptos coin
    public entry fun withdraw_fund(
        sender: &signer,
        withdraw_amount: u64
    ) acquires BalanceManagement, DepositManagement {
        let client_address = signer::address_of(sender);
        let deposit_management_addr = get_deposit_management_object_address();
        ensure_contract_enabled(deposit_management_addr);
        ensure_whitelisted_client(client_address, deposit_management_addr);

        assert!(withdraw_amount > 0, error::invalid_argument(EAMOUNT_CANNOT_BE_ZERO));

        let balance_management = borrow_global_mut<BalanceManagement>(get_balance_object_address());

        let client_balance_mut = table::borrow_mut(&mut balance_management.client_balance, client_address);
        let client_balance = *client_balance_mut;

        ensure_enough_balance(client_balance, withdraw_amount);

        *client_balance_mut = client_balance - withdraw_amount;
        let extract_coin = coin::extract(&mut balance_management.total_coin, withdraw_amount);
        coin::deposit<SupraCoin>(client_address, extract_coin);

        // If the client's balance is zero after they withdraw their funds, remove the client from [balance_management.client_balance]
        if (*client_balance_mut == 0) {
            table::remove(&mut balance_management.client_balance, client_address);
        };
    }

    // #######################################################################################
    //        :::::::::::::::::::::::::: VIEW FUNCTIONS ::::::::::::::::::::::::::
    // #######################################################################################

    #[view]
    public fun get_deposit_management_object_address(): address {
        return object::create_object_address(&@supra_addr, SEED_DEPOSIT_MANAGEMENT)
    }

    #[view]
    public fun get_balance_object_address(): address {
        return object::create_object_address(&@supra_addr, SEED_BALANCE)
    }

    #[view]
    /// Check that is Client account and there contract is whitelisted
    public fun is_contract_eligible(
        client_address: address,
        contract_address: address
    ): bool acquires DepositManagement {
        if (is_client_whitelisted(client_address)) {
            let deposit_management_addr = get_deposit_management_object_address();
            let deposit_management = borrow_global<DepositManagement>(deposit_management_addr);
            let whitelist_client = table::borrow(&deposit_management.whitelist_clients, client_address);
            vector::contains(&whitelist_client.whitelisted_contract_address, &contract_address)
        } else {
            false
        }
    }

    #[view]
    /// Check that is client account address is whitelisted or not
    public fun is_client_whitelisted(client_address: address): bool acquires DepositManagement {
        let deposit_management_addr = get_deposit_management_object_address();
        let deposit_management = borrow_global<DepositManagement>(deposit_management_addr);
        table::contains(&deposit_management.whitelist_clients, client_address)
    }

    #[view]
    /// is minimum balance reached
    public fun has_minimum_balance_reached(
        client_address: address
    ): bool acquires BalanceManagement, DepositManagement {
        let deposit_management_addr = get_deposit_management_object_address();
        ensure_whitelisted_client(client_address, deposit_management_addr);
        let client_fund = check_client_fund(client_address);
        let min_balance = check_min_balance(client_address);
        client_fund <= min_balance
    }

    #[view]
    /// Check client fund
    public fun check_client_fund(client_address: address): u64 acquires BalanceManagement {
        let balance_management = borrow_global<BalanceManagement>(get_balance_object_address());

        if (table::contains(&balance_management.client_balance, client_address)) {
            *table::borrow(&balance_management.client_balance, client_address)
        } else {
            0
        }
    }

    #[view]
    /// Check min balance of client & supra , whatever is higher value it will return
    public fun check_min_balance(client_address: address): u64 acquires DepositManagement {
        let min_balance_client = check_min_balance_client(client_address);
        let min_balance_supra = check_min_balance_supra();

        if (min_balance_client > min_balance_supra) {
            min_balance_client
        } else {
            min_balance_supra
        }
    }

    #[view]
    /// Check and return supra minimum balance
    public fun check_min_balance_supra(): u64 acquires DepositManagement {
        let deposit_management_addr = get_deposit_management_object_address();
        borrow_global<DepositManagement>(deposit_management_addr).min_balance_limit_supra
    }

    #[view]
    /// Check and return minimum balance of client
    public fun check_min_balance_client(client_address: address): u64 acquires DepositManagement {
        let deposit_management_addr = get_deposit_management_object_address();
        ensure_whitelisted_client(client_address, deposit_management_addr);
        let deposit_management_addr = get_deposit_management_object_address();
        table::borrow(
            &borrow_global<DepositManagement>(deposit_management_addr).whitelist_clients,
            client_address
        ).min_balance_limit
    }

    #[view]
    /// Check client effective balance "client_fund - min_balance"
    public fun check_effective_balance(client_address: address): u64 acquires DepositManagement, BalanceManagement {
        let deposit_management_addr = get_deposit_management_object_address();
        ensure_whitelisted_client(client_address, deposit_management_addr);
        let client_fund = check_client_fund(client_address);
        let min_balance = check_min_balance(client_address);
        if (client_fund > min_balance) { client_fund - min_balance } else { 0 }
    }

    #[view]
    /// Get the clients all whitelisted contracts
    public fun get_clients_contract(client_address: address): vector<address> acquires DepositManagement {
        let deposit_management_addr = get_deposit_management_object_address();
        ensure_whitelisted_client(client_address, deposit_management_addr);
        let deposit_management_addr = get_deposit_management_object_address();
        table::borrow(
            &borrow_global<DepositManagement>(deposit_management_addr).whitelist_clients,
            client_address
        ).whitelisted_contract_address
    }

    #[view]
    /// Get the client subscription period info
    public fun get_subscription_by_client(client_address: address): SubscriptionPeriod acquires DepositManagement {
        let deposit_management_addr = get_deposit_management_object_address();
        ensure_whitelisted_client(client_address, deposit_management_addr);
        let deposit_management_addr = get_deposit_management_object_address();
        *table::borrow(&borrow_global<DepositManagement>(deposit_management_addr).subscription_period, client_address)
    }

    #[view]
    /// Get client balance and min balance info from address
    public fun get_balance_of_client(
        addresses: vector<address>
    ): vector<ClientBalanceInfo> acquires DepositManagement, BalanceManagement {
        let size = vector::length(&addresses);
        assert!(size > 0, error::invalid_argument(0));
        let deposit_management_addr = get_deposit_management_object_address();

        let client_balance_info = vector[];
        let i = 0;
        while (i < size) {
            let client_address = *vector::borrow(&addresses, i);
            i = i + 1;
            if (table::contains(
                &borrow_global<DepositManagement>(deposit_management_addr).whitelist_clients,
                client_address
            )) {
                let balance = check_client_fund(client_address);
                let min_balance_limit = check_min_balance(client_address);
                vector::push_back(&mut client_balance_info, ClientBalanceInfo {
                    client_address, min_balance_limit, balance
                });
            } else {
                vector::push_back(&mut client_balance_info, ClientBalanceInfo {
                    client_address, min_balance_limit: 0, balance: 0
                });
            };
        };
        client_balance_info
    }

    // ======================================================================
    //   Unit test cases
    // ======================================================================

    #[test_only]
    fun set_up_test(supra: &signer, supra_framework: &signer) {
        supra_framework::account::create_account_for_test(signer::address_of(supra));
        let (burn, mint) = supra_framework::supra_coin::initialize_for_test(supra_framework);

        init_module(supra);
        coin::destroy_burn_cap(burn);
        coin::destroy_mint_cap(mint);
    }

    #[test(supra = @supra_addr, supra_framework = @supra_framework)]
    fun test_add_client_address(supra: &signer, supra_framework: &signer) acquires DepositManagement {
        timestamp::set_time_has_started_for_testing(supra_framework);
        set_up_test(supra, supra_framework);

        let client_address = @0xc1;
        add_client_address(supra, client_address); // Add client account address to whitelist
        assert!(is_client_whitelisted(client_address), error::not_found(1))
    }

    #[test(supra = @supra_addr, supra_framework = @supra_framework)]
    #[expected_failure(abort_code = 393218, location = Self)]
    fun test_is_client_whitelisted_failure(supra: &signer, supra_framework: &signer) acquires DepositManagement {
        set_up_test(supra, supra_framework);

        let client_address = @0xc1;
        assert!(is_client_whitelisted(client_address), error::not_found(2))
    }

    #[test(supra = @supra_addr, supra_framework = @supra_framework)]
    fun test_remove_client_address(
        supra: &signer,
        supra_framework: &signer
    ) acquires BalanceManagement, DepositManagement {
        timestamp::set_time_has_started_for_testing(supra_framework);
        set_up_test(supra, supra_framework);

        let client_address = @0xc1;
        add_client_address(supra, client_address); // Add client address to whitelist
        assert!(is_client_whitelisted(client_address), error::not_found(3));

        remove_client_address(supra, client_address, true); // remove client address from whitelist
        assert!(!is_client_whitelisted(client_address), error::not_found(4));
    }

    #[test(supra = @supra_addr, supra_framework = @supra_framework)]
    #[expected_failure(abort_code = 393217, location = Self)]
    fun test_remove_client_address_failure(
        supra: &signer,
        supra_framework: &signer
    ) acquires BalanceManagement, DepositManagement {
        set_up_test(supra, supra_framework);

        let client_address = @0xc1;
        remove_client_address(supra, client_address, false);
        assert!(!is_client_whitelisted(client_address), error::not_found(5));
    }

    #[test(supra = @supra_addr, client = @0xc1, supra_framework = @supra_framework)]
    fun test_client_deposit_fund_add_withdraw(
        supra: &signer,
        client: &signer,
        supra_framework: &signer
    ) acquires BalanceManagement, DepositManagement {
        timestamp::set_time_has_started_for_testing(supra_framework);
        let client_address = signer::address_of(client);
        supra_framework::account::create_account_for_test(client_address);
        supra_framework::account::create_account_for_test(signer::address_of(supra));

        let (burn, mint) = supra_framework::supra_coin::initialize_for_test(supra_framework);
        coin::register<SupraCoin>(client);

        init_module(supra);

        add_client_address(supra, client_address); // Add client address to whitelist

        let balance_management = borrow_global<BalanceManagement>(get_balance_object_address());
        assert!(coin::value<SupraCoin>(&balance_management.total_coin) == 0, error::internal(6));

        let coin = coin::mint<SupraCoin>(1000000000, &mint);
        coin::deposit(client_address, coin);
        assert!(coin::balance<SupraCoin>(client_address) == 1000000000, error::internal(7)); // Check Client balance

        deposit_fund(client, 110000000); // 1.1 Aptos Client Deposit

        let balance_management = borrow_global<BalanceManagement>(get_balance_object_address());
        assert!(
            coin::value<SupraCoin>(&balance_management.total_coin) == 110000000,
            error::internal(8)
        ); // Check Resource account balance
        assert!(
            coin::balance<SupraCoin>(client_address) == 890000000,
            error::internal(9)
        ); // Check Client balance again

        withdraw_fund(client, 110000000); // 1.1 Aptos withdraw from client
        let balance_management = borrow_global<BalanceManagement>(get_balance_object_address());

        assert!(coin::balance<SupraCoin>(client_address) == 1000000000, error::internal(10));
        assert!(
            coin::value<SupraCoin>(&balance_management.total_coin) == 0,
            error::internal(11)
        ); // Check Resource account balance

        coin::destroy_burn_cap(burn);
        coin::destroy_mint_cap(mint);
    }

    #[test(supra = @supra_addr, client = @0xc1, supra_framework = @supra_framework)]
    fun test_add_contract_to_whitelist(
        supra: &signer,
        client: &signer,
        supra_framework: &signer
    ) acquires DepositManagement {
        timestamp::set_time_has_started_for_testing(supra_framework);
        set_up_test(supra, supra_framework);

        let client_address = signer::address_of(client);
        add_client_address(supra, client_address); // Add client address to whitelist

        let contract_address = @0xca01;
        add_contract_to_whitelist(client, contract_address); // Add contract address to whitelist from client

        assert!(vector::length(&get_clients_contract(client_address)) == 1, error::internal(12));
        assert!(is_contract_eligible(client_address, contract_address), error::not_found(13));
    }

    #[test(supra = @supra_addr, client = @0xc1, supra_framework = @supra_framework)]
    #[expected_failure(abort_code = 524296, location = Self)]
    fun test_add_contract_to_whitelist_failure(
        supra: &signer,
        client: &signer,
        supra_framework: &signer
    ) acquires DepositManagement {
        timestamp::set_time_has_started_for_testing(supra_framework);
        set_up_test(supra, supra_framework);

        let client_address = signer::address_of(client);
        add_client_address(supra, client_address); // Add client address to whitelist

        let contract_address = @0xca01;
        add_contract_to_whitelist(client, contract_address); // Add contract address to whitelist from client

        assert!(vector::length(&get_clients_contract(client_address)) == 1, error::internal(14));
        assert!(is_contract_eligible(client_address, contract_address), error::not_found(15));
        add_contract_to_whitelist(client, contract_address); // Add same contract address to whitelist from client
    }

    #[test(supra = @supra_addr, client = @0xc1, supra_framework = @supra_framework)]
    fun test_remove_contract_from_whitelist(
        supra: &signer,
        client: &signer,
        supra_framework: &signer
    ) acquires DepositManagement {
        timestamp::set_time_has_started_for_testing(supra_framework);
        set_up_test(supra, supra_framework);

        let client_address = signer::address_of(client);
        add_client_address(supra, client_address); // Add client address to whitelist

        let contract_address = @0xca01;
        add_contract_to_whitelist(client, contract_address); // Add contract address to whitelist from client

        assert!(vector::length(&get_clients_contract(client_address)) == 1, error::internal(16));
        assert!(is_contract_eligible(client_address, contract_address), error::not_found(17));

        remove_contract_from_whitelist(client, contract_address); // Remove contract address from whitelist
        assert!(vector::length(&get_clients_contract(client_address)) == 0, error::internal(18));
    }

    #[test(supra = @supra_addr, client = @0xc1, supra_framework = @supra_framework)]
    #[expected_failure(abort_code = 393235, location = Self)]
    fun test_remove_contract_from_whitelist_test(
        supra: &signer,
        client: &signer,
        supra_framework: &signer
    ) acquires DepositManagement {
        timestamp::set_time_has_started_for_testing(supra_framework);
        set_up_test(supra, supra_framework);

        let client_address = signer::address_of(client);
        add_client_address(supra, client_address); // Add client address to whitelist
        let contract_address = @0xca01;

        assert!(is_contract_eligible(client_address, contract_address), error::not_found(19));
        remove_contract_from_whitelist(client, contract_address); // Remove contract address from whitelist
    }

    #[test(supra = @supra_addr, supra_framework = @supra_framework)]
    #[expected_failure(abort_code = 327685, location = Self)]
    fun test_set_contract_disabling(supra: &signer, supra_framework: &signer) acquires DepositManagement {
        set_up_test(supra, supra_framework);

        let client_address = @0xc1;
        set_contract_disabling(supra, true); // set contract disable mode
        add_client_address(supra, client_address); // it will not perform any actions seems contract is disabled
    }

    #[test(supra = @supra_addr, supra_framework = @supra_framework)]
    fun test_set_min_balance_limit_supra(supra: &signer, supra_framework: &signer) acquires DepositManagement {
        set_up_test(supra, supra_framework);

        assert!(
            check_min_balance_supra() == MIN_BALANCE_LIMIT,
            error::invalid_state(20)
        ); // check default min balance limit
        set_min_balance_limit_supra(supra, 800000000); // set min balance limit of supra
        assert!(check_min_balance_supra() == 800000000, error::invalid_state(21));
    }

    #[test(supra = @supra_addr, client = @0xc1, supra_framework = @supra_framework)]
    fun test_client_setting_minimum_balance(
        supra: &signer,
        client: &signer,
        supra_framework: &signer
    ) acquires DepositManagement {
        timestamp::set_time_has_started_for_testing(supra_framework);
        set_up_test(supra, supra_framework);

        let client_address = signer::address_of(client);
        add_client_address(supra, client_address); // Add client address to whitelist

        assert!(
            check_min_balance(client_address) == MIN_BALANCE_LIMIT,
            error::invalid_state(22)
        ); // check client min balance limit
        client_setting_minimum_balance(client, 800000000); // set min balance limit of client
        assert!(check_min_balance(client_address) == 800000000, error::invalid_state(23));
    }
}

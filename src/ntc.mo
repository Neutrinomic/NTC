import ICRCLedger "mo:devefi-icrc-ledger";
import IC "./services/ic";
import Principal "mo:base/Principal";
import Account "mo:account";
import Debug "mo:base/Debug";
import Blob "mo:base/Blob";

import Nat "mo:base/Nat";
import Cycles "mo:base/ExperimentalCycles";
import BTree "mo:stableheapbtreemap/BTree";
import Nat64 "mo:base/Nat64";

import RQQ "mo:rqq";
import Nat32 "mo:base/Nat32";
import Old "old";
import Address "address";

( with migration = func ({
        NTC2Can : BTree.BTree<Nat64, Old.NTC2Can_request>;
    }) : {
        NTC2Can : Nat;
    } = {
        NTC2Can = 0;
    }
) persistent actor class NTCminter({ledgerId : Principal}) = this {

  
    transient let T = 1_000_000_000_000;
    transient let NTC_to_canister_fee = 500000; // ~0,65 cents
    transient let NTC_ledger_id = Principal.toText(ledgerId);

    let NTC_mem_v1 = ICRCLedger.Mem.Ledger.V1.new();
    let NTC_mem_v2 = ICRCLedger.Mem.Ledger.V2.upgrade(NTC_mem_v1);
    transient let NTC_ledger = ICRCLedger.Ledger<system>(NTC_mem_v2, NTC_ledger_id, #id(0), Principal.fromActor(this));

    private transient let ic : IC.Self = actor ("aaaaa-aa");


    let NTC2Can : Nat = 0; // No idea how to delete stable variables with EOP yet


    var topped_up : Nat = 0;
    var failed_topups : Nat = 0;

    public type Action = {
        from : Account.Account;
        to : Principal;
        amount : Nat;
        task : {
            #refill;
            #call: (memo: Blob);
        }
    };

    let rqq_mem_v1 = RQQ.Mem.V1.new<Action>();
    transient let rqq = RQQ.RQQ<system, Action>(rqq_mem_v1, null);

    type NTC_call_endpoint = actor {
        ntc: (Account.Account, Blob) -> async ();
    };


    rqq.dispatch := ?(func (action: Action) : async* () {
        switch (action.task) {
            case (#refill) {
                await (with cycles = action.amount) ic.deposit_cycles({ canister_id = action.to });
                topped_up += action.amount;
            };
            case (#call(memo)) {
                let can = actor (Principal.toText(action.to)) : NTC_call_endpoint;
                await (with cycles = action.amount; timeout = 20) can.ntc(action.from, memo);
            };
        };
    });

    rqq.onDropped := ?(func (action: Action) : () {
        failed_topups += action.amount;
    });

    NTC_ledger.onReceive(
            func<system>(t:ICRCLedger.Transfer) {
            // Strategy: Unlike TCycles ledger, we will retry refilling the canister
            // if it doesn't work, the NTC gets burned. No NTC is gets returned if the subaccount is not a valid canister.
            let ?minter = NTC_ledger.getMinter() else Debug.trap("Err getMinter not set");
            let ?subaccount = t.to.subaccount else return;
            let #icrc(account) = t.from else return;

            if (t.amount < NTC_ledger.getFee()*2 or t.amount < NTC_to_canister_fee*2) return;

            // We add them based on amount and request id so we can pick the largest requests first
            let priority : Nat32 = Nat32.fromNat(Nat64.toNat((Nat64.fromNat(t.amount) / 1_0000_0000) & 0xFFFF_FFFF));
            let ?(canister, sa_type) = Address.subaccount2canister(Blob.toArray(subaccount)) else return;
            switch (sa_type) {
                case (#refill) {
                    rqq.add<system>({
                        from = account;
                        to = canister;
                        amount = (t.amount - NTC_to_canister_fee) * 1_00_00;
                        task = #refill;
                    }, priority);
                };
                case (#call) {
                    let ?memo = t.memo else return;
                    rqq.add<system>({
                        from = account;
                        to = canister;
                        amount = (t.amount - NTC_to_canister_fee) * 1_00_00;
                        task = #call(memo);
                    }, priority);
                };
            };

            // Burn
            ignore NTC_ledger.send({
                to = #icrc(minter);
                amount = t.amount;
                from_subaccount = ?subaccount;
                memo = null;
            });
        }
    );

    public shared ({ caller }) func mint(to : Account.Account) : async () {

        // Here we accept native cycles to mint NTC
        let received = Cycles.accept<system>(Cycles.available());
        if (received < T / 100) Debug.trap("Minimum 0.01T");

        // Convert from 12 decimals to 8
        let amount = received / 1_00_00;

        // Mint
        ignore NTC_ledger.send({
            to = #icrc(to);
            amount = amount;
            from_subaccount = null;
            memo = ?Address.canister2subaccount(caller, #refill);
        });

    };



    // Other helper functions -----


    type Stats = {
        cycles : Nat;
        topped_up : Nat;
        failed_topups : Nat;
    };

    public query func stats() : async Stats {
        {
            cycles = Cycles.balance();
            topped_up = topped_up;
            failed_topups = failed_topups;
        };
    };


    type GetAccount = {
        refill : Account.Account;
        refill_text: Text;
        call : Account.Account;
    };

    public query func get_account(canister_id : Principal) : async GetAccount {
        let acc : Account.Account = {
            owner = Principal.fromActor(this);
            subaccount = ?Address.canister2subaccount(canister_id, #refill);
        };
        let acc_call : Account.Account = {
            owner = Principal.fromActor(this);
            subaccount = ?Address.canister2subaccount(canister_id, #call);
        };
        let ?(back, sa_type) = Address.subaccount2canister(Blob.toArray(Address.canister2subaccount(canister_id, #refill))) else Debug.trap("Has to be a canister");
        assert(back == canister_id and sa_type == #refill);

        {
            refill = acc;
            refill_text = Account.toText(acc);
            call = acc_call;
        };
    };


    public query func get_queue() : async [(Nat64, rqq.Debug.RequestShared<Action>)] {
        rqq.Debug.getRequests(0, 100).requests;
    };

    public query func get_dropped() : async [(Nat64, rqq.Debug.RequestShared<Action>)] {
        rqq.Debug.getDropped(0, 100).dropped;
    };


};

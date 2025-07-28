import ICRCLedger "mo:devefi-icrc-ledger";
import IC "./services/ic";
import Principal "mo:base/Principal";
import Account "mo:account";
import Debug "mo:base/Debug";
import Blob "mo:base/Blob";
import Iter "mo:base/Iter";
import Array "mo:base/Array";
import Nat "mo:base/Nat";
import Cycles "mo:base/ExperimentalCycles";
import BTree "mo:stableheapbtreemap/BTree";
import Nat64 "mo:base/Nat64";
import IT "mo:itertools/Iter";
import Nat8 "mo:base/Nat8";

import RQQ "mo:rqq";
import Nat32 "mo:base/Nat32";

persistent actor class NTCminter({ledgerId : Principal}) = this {

  
    transient let T = 1_000_000_000_000;
    transient let NTC_to_canister_fee = 500000; // ~0,65 cents
    transient let NTC_ledger_id = Principal.toText(ledgerId);

    let NTC_mem_v1 = ICRCLedger.Mem.Ledger.V1.new();
    transient let NTC_ledger = ICRCLedger.Ledger<system>(NTC_mem_v1, NTC_ledger_id, #id(0), Principal.fromActor(this));

    private transient let ic : IC.Self = actor ("aaaaa-aa");

    type NTC2Can_request_shared = {
        amount : Nat;
        canister : Principal;
        retry : Nat;
        last_try : Nat64;
    };

    type NTC2Can_request = {
        amount : Nat;
        canister : Principal;
        var retry : Nat;
        var last_try : Nat64;
    };


    let NTC2Can = BTree.init<Nat64, NTC2Can_request>(?32); // 32 is the order, or the size of each BTree node


    private func canister2subaccount(canister_id : Principal, sa_type : SubaccountType) : Blob {
        let can = Blob.toArray(Principal.toBlob(canister_id));
        let size = can.size();
        let pad_start = 32 - size - 1:Nat;
        var sa = Iter.toArray(IT.flattenArray<Nat8>([
            Array.tabulate<Nat8>(pad_start, func _ = 0),
            can,
            [Nat8.fromNat(size)]
            ]));

        if (sa_type == #call) {
            let va = Array.thaw<Nat8>(sa);
            va[0] := 1;
            sa := Array.freeze<Nat8>(va);
        };

        Blob.fromArray(sa);
    };

    type SubaccountType = { #call; #refill };
    private func subaccount2canister(subaccount : [Nat8]) : ?(Principal, SubaccountType) {
        if (subaccount.size() != 32) return null;
        let sa_type : SubaccountType = if (subaccount[0] == 1) #call else #refill;
        let size = Nat8.toNat(subaccount[31]);
        if (size == 0 or size > 20) return null;
        let p = Principal.fromBlob(Blob.fromArray(Iter.toArray(Array.slice(subaccount, 31 - size:Nat, 31))));
        if (Principal.isAnonymous(p)) return null;
        if (Principal.toText(p).size() != 27) return null; 
        ?(p, sa_type)
    };

   

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
            let ?(canister, sa_type) = subaccount2canister(Blob.toArray(subaccount)) else return;
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
            memo = ?canister2subaccount(caller, #refill);
        });

    };

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

    public query func get_account(canister_id : Principal) : async (Account.Account, Text, Principal, Account.Account) {
        let acc : Account.Account = {
            owner = Principal.fromActor(this);
            subaccount = ?canister2subaccount(canister_id, #refill);
        };
        let acc_call : Account.Account = {
            owner = Principal.fromActor(this);
            subaccount = ?canister2subaccount(canister_id, #call);
        };
        let ?(back, _sa_type) = subaccount2canister(Blob.toArray(canister2subaccount(canister_id, #refill))) else Debug.trap("Has to be a canister");

        (
            acc,
            Account.toText(acc),
            back,
            acc_call,
        );
    };


    public query func get_queue() : async [(Nat64, rqq.Debug.RequestShared<Action>)] {
        rqq.Debug.getRequests(0, 100).requests;
    };

    public query func get_dropped() : async [(Nat64, rqq.Debug.RequestShared<Action>)] {
        rqq.Debug.getDropped(0, 100).dropped;
    };


};

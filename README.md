<img width="1024" height="1024" alt="NTC_BIG" src="https://github.com/user-attachments/assets/356ac699-8ee1-49c0-a877-d065504419ea" />

# NTC (NCycles) Neutrinite T Cycles

NTC ledger: 7dx3o-7iaaa-aaaal-qsrdq-cai

NTC minter: 7ew52-sqaaa-aaaal-qsrda-cai

**⚡🔋⚡ Feature: Canister top-up addresses. Each canister has an address that automatically detects when NTC is sent to it and tops up the canister with cycles. ⚡🔋⚡**

## Mint with dfx

dfx canister --network ic call 7ew52-sqaaa-aaaal-qsrda-cai mint --with-cycles 10T --wallet `dfx identity get-wallet --network ic`

You will be asked for Account - This is where you will get the NTC.

The canister from which cycles come from is logged inside the mint transaction memo for accountability.

## Get your canister top-up address

Use the method `get_account` https://dashboard.internetcomputer.org/canister/7ew52-sqaaa-aaaal-qsrda-cai

Example canister top-up address: `7ew52-sqaaa-aaaal-qsrda-cai-37zkjwy.abcdebd801010a`
Always starts with '7ew52-sqaaa-aaaal-qsrda-cai'

## Topping up ⚡🔋⚡

When you send NTC to the given text ICRC top-up address, the NTC will be burned and the canister will receive cycles.

The canister top-up address is permanent. You can publish it on your website for others to top up your canisters with a transaction from their wallets.

The requests with most NTC gets processed first to prevent DoS attacks. Every 6 seconds the system processes 20 requests in parallel. Will be increased if needed.

If sending to non-existent canister/principal, there are no refunds. Sending will fail. Only send to accounts obtained from get_account.
You could also take the canister2subaccount function and generate these addresses locally.

If sending to unavailable subnet, the request will be retried 11 times - 5 min between retries. If that doesn't work after 55min, the NTC is lost.

It's a one way topping up.

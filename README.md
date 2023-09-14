<img width="819" alt="image" src="https://github.com/stakehouse-dev/zec-alpha/assets/102478146/60251d2e-2237-488c-8dab-4c85f1178e7b">

# What is ZEC?
Zero ETH Club (ZEC) is a permissioned pool of node operators allowing them to run a validator without any ETH stake (i.e Zero ETH). In return for costs incurred running a node, they earn 10% of the network revenue received by the validator (ETH execution layer earnings). Node operators need to pay a social recovery bond (approx. USD100 in ETH per BLS key) as security for key recovery (CIP) in the event they do not run the node and it sustains leakage.

# Who can join ZEC?
In the ZEC, there is a maximum ceiling on the amount of ETH that can be staked through ZEC node operators. This limit can be adjusted periodically based on decisions made by a DAO or a committee that is elected through a community-driven process. Additionally, ZEC maintains a voluntary inclusion list for allowed LSD networks, facilitating ZEC node operators to join them.

The endorsement of new node operators and the inclusion in the ZEC LSD network list are determined through a social consensus mechanism through the governing ZEC parent DAO or the protocol network DAO. The objective of implementing a community-driven opt-in mechanism and maintaining a curated list of node operators is to ensure the sustained optimal performance of nodes within the ZEC network, while minimizing the unplanned removal of validators.

# How does ZEC staking work?
A liquidity provider can deposit any amount of ETH in the ZEC pool that ZEC node operators can use to fund validators. The deposits are allocated into batches of 4 ETH. On top of this, the Giant Fees and MEV pool should have 4 ETH and the Giant Protected Staking pool have 24 ETH sitting ideally. As soon as the amount is available, the node operator can go ahead and register a BLS public key. If all the pools have enough ETH for multiple validators, then the node operator can also register multiple BLS public keys in a batch.

This step only registers and brings ETH to the allocated smart wallet ready to be staked. Once all the ETH is present in the smart wallet, the node operator can stake the validator in the next step.

# How are the rewards distributed?
Once the validator has minted derivatives, and it has started earning rewards, the Giant Protected Staking pool depositors and the Giant MEV pool depositors receive rewards on a pro-rata basis as usual. 
The ZEC pool receives 50% of all the MEV rewards and the other 50% go to the Giant MEV pool or fren mev pool. Out of the 50% rewards pouring into the ZEC pool, 20% goes to the ZEC node operators and the remaining 80% goes to the ZEC liquidity providers which is then distributed on a pro-rata basis. Simply speaking, 10% of all the MEV rewards distributed by the syndicate goes to the ZEC node operators, 40% goes to the ZEC depositors (which is distributed amongst them on a pro-rata basis) and 50% goes to the Giant MEV pool depositors or fren mev pool (distributed on a pro-rata basis).

# What if the ZEC pool has enough ETH for a BLS public key but the giant pools don’t?
The ZEC contract allows the node operators to register the BLS public keys (if the ZEC has at least 4 ETH * number of BLS keys being registered) even if there is not enough ETH in the other giant pools. Once the node operator finds that there is enough ETH in the giant pools, they can come back and trigger a deposit to the Ethereum deposit contract via the ZEC contract. As a matter of fact, this step can be triggered by anyone and not just the node operator. Additionally, ETH can come from fren delegation.

# Are there any limits on the number of BLS public keys that can be staked?
Yes, the ZEC contract defines a limit on total BLS public keys that can be staked across all networks. There is also a limit on the number of BLS public keys that an individual ZEC node operator can stake. Although, the DAO can update the total number of BLS public keys that can be staked by the contract across all LSD networks.

# What if a node operator misbehaves?
When a ZEC node operator registers a BLS public key, they are required to make a one time deposit of the CIP bond amount in the event that their validator(s) leak more than 0.2 ETH. If this is the case ZEC will allow the validator to be ejected from the Stakehouse protocol, recovering the unstaked balance which can then be used to rotate into a new BLS key.

# Can a node operator belong to multiple LSDs?
Yes and no. A node operator is allowed to join as many LSDs as they want, but in the ZEC they can only represent a single LSD.

The node operators can be whitelisted either by the network DAO or the DAO committee members. The node operator can also be banned by either of the DAOs.

The DAO committee and the network DAO have the ability to whitelist multiple node operators in a single transaction.

import {
  GeneratedType,
  OfflineSigner,
  EncodeObject,
  Registry,
} from "@cosmjs/proto-signing";
import { StdFee } from "@cosmjs/launchpad";
import { SigningStargateClient } from "@cosmjs/stargate";
import { Env } from "./env";
import { UnionToIntersection, Return, Constructor } from "./helpers";
import { Module } from "./modules";
import { EventEmitter } from "events";
import { ChainInfo } from "@keplr-wallet/types";

const defaultFee = {
  amount: [],
  gas: "200000",
};

export class IgniteClient extends EventEmitter {
	static plugins: Module[] = [];
  env: Env;
  signer: OfflineSigner;
  registry: Array<[string, GeneratedType]> = [];
  static plugin<T extends Module | Module[]>(plugin: T) {
    const currentPlugins = this.plugins;

    class AugmentedClient extends this {
      static plugins = currentPlugins.concat(plugin);
    }

    if (Array.isArray(plugin)) {
      type Extension = UnionToIntersection<Return<T>['module']>
      return AugmentedClient as typeof AugmentedClient & Constructor<Extension>;  
    }

    type Extension = Return<T>['module']
    return AugmentedClient as typeof AugmentedClient & Constructor<Extension>;
  }
  async signAndBroadcast(msgs: EncodeObject[], fee: StdFee, memo: string) {
    const { address } = (await this.signer.getAccounts())[0]; 
    const signingClient = await SigningStargateClient.connectWithSigner(this.env.rpcURL, this.signer, {registry: new Registry(this.registry), prefix: this.env.prefix});
		return await signingClient.signAndBroadcast(address, msgs, fee ? fee : defaultFee, memo)
  }
  constructor(env: Env, signer: OfflineSigner) {
    super();
    this.env = env;
    this.signer = signer;
    const classConstructor = this.constructor as typeof IgniteClient;
    classConstructor.plugins.forEach(plugin => {
      const pluginInstance = plugin(this);
      Object.assign(this, pluginInstance.module)
      if (this.registry) {
        this.registry = this.registry.concat(pluginInstance.registry)
      }
		});		
  }

  async useKeplr(keplrChainInfo: Partial<ChainInfo>) {
    // Using queryClients directly because BaseClient has no knowledge of the modules at this stage
    try {
      const queryClient = (
        await import("./cosmos.base.tendermint.v1beta1/module")
      ).queryClient;
      const stakingQueryClient = (
        await import("./cosmos.staking.v1beta1/module")
      ).queryClient;
      const bankQueryClient = (await import("./cosmos.bank.v1beta1/module"))
        .queryClient;

      const stakingqc = stakingQueryClient({ addr: this.env.apiURL });
      const qc = queryClient({ addr: this.env.apiURL });
      const node_info = await (await qc.serviceGetNodeInfo()).data;
      const chainId = node_info.default_node_info?.network ?? "";
      const chainName = chainId?.toUpperCase() + " Network";
      const staking = await (await stakingqc.queryParams()).data;
      const bankqc = bankQueryClient({ addr: this.env.apiURL });
      const tokens = await (await bankqc.queryTotalSupply()).data;
      const addrPrefix = this.env.prefix ?? "cosmos";
      const rpc = this.env.rpcURL;
      const rest = this.env.apiURL;
      let features = ["no-legacy-stdTx"];
      let stakeCurrency = {
        coinDenom: staking.params?.bond_denom?.toUpperCase() ?? "",
        coinMinimalDenom: staking.params?.bond_denom ?? "",
        coinDecimals: 0,
      };

      let bip44 = {
        coinType: 118,
      };

      let bech32Config = {
        bech32PrefixAccAddr: addrPrefix,
        bech32PrefixAccPub: addrPrefix + "pub",
        bech32PrefixValAddr: addrPrefix + "valoper",
        bech32PrefixValPub: addrPrefix + "valoperpub",
        bech32PrefixConsAddr: addrPrefix + "valcons",
        bech32PrefixConsPub: addrPrefix + "valconspub",
      };

      let currencies =
        tokens.supply?.map((x) => {
          const y = {
            coinDenom: x.denom?.toUpperCase() ?? "",
            coinMinimalDenom: x.denom ?? "",
            coinDecimals: 0,
          };
          return y;
        }) ?? [];

      let feeCurrencies =
        tokens.supply?.map((x) => {
          const y = {
            coinDenom: x.denom?.toUpperCase() ?? "",
            coinMinimalDenom: x.denom ?? "",
            coinDecimals: 0,
          };
          return y;
        }) ?? [];

      let coinType = 118;

      if (chainId) {
        const suggestOptions: ChainInfo = {
          features,
          chainId,
          chainName,
          rpc,
          rest,
          stakeCurrency,
          bip44,
          bech32Config,
          currencies,
          feeCurrencies,
          coinType,
          ...keplrChainInfo,
        };
        await window.keplr.experimentalSuggestChain(suggestOptions);

        window.keplr.defaultOptions = {
          sign: {
            preferNoSetFee: true,
            preferNoSetMemo: true,
          },
        };
      }
      await window.keplr.enable(chainId);
      this.signer = window.keplr.getOfflineSigner(chainId);
      this.emit("signer-changed", this.signer);
    } catch (e) {
      throw new Error(
        "Could not load tendermint, staking and bank modules. Please ensure your client loads them to use useKeplr()"
      );
    }
  }
}
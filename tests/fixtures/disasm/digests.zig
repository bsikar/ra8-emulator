//! The digest each printer sweep in tests/chip/core/cpu/text must reach (see
//! tests/chip/core/cpu/text/digest.zig). Captured from a sweep in which every
//! encoding printed exactly as the reference disassembler printed it. When a printer changes on
//! purpose, the failing test prints the replacement line.
const std = @import("std");

pub const Entry = struct {
    group: []const u8,
    call: u64,
    count: u32,
    sha256: []const u8,
};

pub fn find(group: []const u8, call: u64) ?Entry {
    for (all) |entry| {
        if (entry.call == call and std.mem.eql(u8, entry.group, group)) return entry;
    }
    return null;
}

pub const all = [_]Entry{
    .{ .group = "acq_rel", .call = 0x4f2ca459d7b032e3, .count = 210, .sha256 = "b0b4701daf642b0ca2857ba3d6717eedead9ffd3b67537166e44efd041f839bb" },
    .{ .group = "add_sub", .call = 0xdd493527ec7c86f7, .count = 10240, .sha256 = "e89121c5e8852488e4d2815ea0766cde0900629baf69688eda312536170a3448" },
    .{ .group = "add_sub_wide", .call = 0xfebabc4201246b74, .count = 6300, .sha256 = "1217e2bac4765f3a5b2c389d2e9b99baf24a1646bcf2189ae6e3164160f450e2" },
    .{ .group = "barrier", .call = 0x7fdb6fec10c80976, .count = 48, .sha256 = "62513a77a7e66f014c3d25f45cd3966d0183ebd06a3b5d5711a27a50795fe668" },
    .{ .group = "bitfield", .call = 0xd3509af10b975b30, .count = 61054, .sha256 = "37a99a1868959db8dcb99c6b6464472eb57a4959ea51bd566ea62f26ba6892d5" },
    .{ .group = "bkpt", .call = 0x861b14b97539e905, .count = 256, .sha256 = "5bd30e81acd4aea033330bc82bfd3a8b10084d4fcac0a6cf13ee37a6cd142baa" },
    .{ .group = "blxns", .call = 0xa72e33e0b3cddb3c, .count = 14, .sha256 = "b614c08c5908943c1e3c9d072b9f3c4a8c1f7a2b2314b83af9f1859cfc51c844" },
    .{ .group = "branch", .call = 0xbe7a26a5bff48f48, .count = 5632, .sha256 = "5cd99f3426cb2decf6595371b4cbc434534ae383a9470db7377654657b2d3217" },
    .{ .group = "branch_wide", .call = 0xf6e44e8b8662f327, .count = 31232, .sha256 = "4b649f966e97e22e5fc64edb22c0312594b6093490c62741b3896231e11cef4a" },
    .{ .group = "bxns", .call = 0x4a8c1ca84359c5ca, .count = 14, .sha256 = "a98d79917f74c114145a8d6179fc7233a3ed931c4967c2837400695359a4fe27" },
    .{ .group = "cbz", .call = 0xfa99a4cfaac7a336, .count = 1024, .sha256 = "b78dc51b9bb8842a3a317ebc8d7c150fd5b70f52ab29aeb6ad11b5e3593dfec8" },
    .{ .group = "cps", .call = 0x5c8f2eb674440919, .count = 12, .sha256 = "4c0ea927e7ce02793a71b5f682cf76f08c443e0af703bb55cf1d0632885b9484" },
    .{ .group = "divide", .call = 0x5835e146b6c4ee0d, .count = 5488, .sha256 = "ea4901d5efb20f47b5230c28ae727890e646470c3430957f9778e5e6b8381473" },
    .{ .group = "dp_reg", .call = 0xb5f5e14ca52e8cd3, .count = 1024, .sha256 = "4460b52e1a34b7ded20bb0a8f67df8b773436e01207c211784545fbb2fa0874c" },
    .{ .group = "dp_shifted", .call = 0x108792d5c4c3163e, .count = 65536, .sha256 = "8471ff7d0a54787c8e0570460d9874fc1448197675820adb5bdca6c990bcbe7f" },
    .{ .group = "dsp_dual", .call = 0x3eeb9765725a245a, .count = 840, .sha256 = "7f4fe79d39b4860de3543926a82f9ec0fc12b40f61c73a0945138a152b121a12" },
    .{ .group = "dsp_dual", .call = 0x648cbfce38ec6170, .count = 840, .sha256 = "26dc1089d3485220bf0c1dbf583a2e7f41d2c7511d6bb241fb28168cac58a654" },
    .{ .group = "dsp_long_mul", .call = 0x358003fc33858d11, .count = 8736, .sha256 = "93fe45c649e347cfa248b64bb1e2fcb47c1b16d3efe4936e6b9d50201a82506f" },
    .{ .group = "dsp_mul16", .call = 0x503a74baeb1ccf53, .count = 10584, .sha256 = "8cb8836a2020ad1c8d73b5c5afb5a373617a828ef454c844ab1732921d46e696" },
    .{ .group = "dsp_mulhi", .call = 0x972b0f5384c1d436, .count = 5880, .sha256 = "6a13231dbdd6291a1a40f3d5a64136c387ceed47ec43ff41c15afa404fcde5ab" },
    .{ .group = "exclusive", .call = 0x95e904da31525ebb, .count = 399, .sha256 = "6745b7735e298747781716793db9bc1af78fdca854209bead5620b3f2582c237" },
    .{ .group = "exclusive", .call = 0x9f8f3b5694051164, .count = 1, .sha256 = "0f9fc21fd0c3bb91e5b4f1086e97546a3a168a5e14a177fea3a3ce5a7473c004" },
    .{ .group = "extend", .call = 0x4e19991bfa99ddf4, .count = 256, .sha256 = "c683d0a26531c9e861323c1faca0493e8e8e13ce95bd9bc4d06d7ab71b09f42d" },
    .{ .group = "extend_b16", .call = 0x36f4d4cbdaafa7e5, .count = 5040, .sha256 = "cc80c172cb4eddf6f4d1019f4be30ea54afecf05cf940e9a65f648f19a32fa3d" },
    .{ .group = "extend_wide", .call = 0x14792a8dd0e35a27, .count = 10080, .sha256 = "8185c5776ed76438edc61f6563c5eba9fee8e0eb3a4d1729785ae70a7157240e" },
    .{ .group = "hint", .call = 0x1cb380de7242b760, .count = 252, .sha256 = "485fed5d8b0f3e11772a80be6460c1d72674f651e3e1a7331970998916f68e8c" },
    .{ .group = "hint", .call = 0x8894ee1a0881e700, .count = 16, .sha256 = "4145862f6dad7792728f7c29e282c3453f666ca0e0e2d26bc71ea9775a33ff65" },
    .{ .group = "imm_arith", .call = 0x784bb93354070e31, .count = 28700, .sha256 = "3572ca0f17823f1ebb7a2e84f886dab7585f03ac012005de94fdbcaee4a37bee" },
    .{ .group = "imm_logic", .call = 0x81758e2ea47262aa, .count = 28616, .sha256 = "5778cd2691c17b8da308b4c74c4b4fa0971c8622c50b34dd7b05c70743473c54" },
    .{ .group = "it", .call = 0x89f0c3cc4580692e, .count = 240, .sha256 = "276c3897fcb9612e54aada8c50946a0d6687efc9844d7c52137f1bc980acb2a5" },
    .{ .group = "ldm_stm", .call = 0x7a0d4e0ca7e7da24, .count = 4080, .sha256 = "828a02dcc625ee9bf6fb1b89e89b73b8260243555e56f83acd56ee6354a31900" },
    .{ .group = "ldm_stm_wide", .call = 0xd9935bf83bf9f721, .count = 1022, .sha256 = "3deb0ee3ccc3bc2f2088f492a351084cdd80ec8f9f6d7228ca379b66df4f915a" },
    .{ .group = "ldr_literal", .call = 0xcc946e1a58712e1a, .count = 2048, .sha256 = "f5322a3bb3b1016b7ba82d34445e9dd9fe31e5e09db79ae1b4f8103bf3659379" },
    .{ .group = "ldr_literal_wide", .call = 0xb78f2a03d8262100, .count = 128, .sha256 = "36f38dca18969333e0a71c8f738dbfd715138f545bcb486fbf073bdd264db44e" },
    .{ .group = "ldrd_strd", .call = 0x3b53c626d426ddf6, .count = 1890, .sha256 = "b4aa272270e1c941f4dae0f832e0263da76ed05abdcb1576739939de0ed0c3e5" },
    .{ .group = "ldst_imm", .call = 0x9fd59f9c0259995b, .count = 16384, .sha256 = "650c726d316c35f715a3d9c1cb34b23a7ec3381a44d4fe5b89a10b4a831b8536" },
    .{ .group = "ldst_reg", .call = 0xe3a0a66c8ab33610, .count = 4096, .sha256 = "a213d052f85bdff353552dbe0c6ccb574ccabeadddb23e1097def263540580a3" },
    .{ .group = "ldst_reg_wide", .call = 0x7028f0f7c6bf8a5f, .count = 1050, .sha256 = "7b2d9e6f66f20c84d73cd07cd296168275c344af295394a2994270940c38f9a6" },
    .{ .group = "ldst_wide", .call = 0xe5e0c6f235573629, .count = 6820, .sha256 = "c19b629ff081a5f14be486a69b512a432ec062d04406e8dc108aa7bbfcabaf25" },
    .{ .group = "long_mul", .call = 0x3f3262925f6d33b3, .count = 4368, .sha256 = "427bfc5ea37c95b7f53990797f8aa2bb2ee25fa898fa9e14ca93727666a0ce68" },
    .{ .group = "misc_wide", .call = 0x99afe35882aba6b2, .count = 28, .sha256 = "f030028d60a6765a33f1aa5a3aec21240db9b97bd2262d25a595e68be6e162ec" },
    .{ .group = "misc_wide", .call = 0xcfdae0e7269112de, .count = 112, .sha256 = "818e4865a14c027dcd2997ceae2d3c576ad365c154f63e53aa03752f0b65d507" },
    .{ .group = "mov_wide", .call = 0xc3415c8607905766, .count = 6272, .sha256 = "9416029c44c2f098af581060fbde62345d41721d72190f177f23a72faf3c1d11" },
    .{ .group = "mrs_msr", .call = 0x1b380608fabbefe6, .count = 546, .sha256 = "e27f15e30caf85f5cd173ffdce499fc172da0bf23f87afd8715257dff7f9f98e" },
    .{ .group = "mrs_msr", .call = 0x1d9364cd08fbf157, .count = 75, .sha256 = "441c4186c75c53a79b1638eec6bad20d93b0e8d53935363b4b04ae9b947ba20a" },
    .{ .group = "mul_acc", .call = 0xfcc5a78c9615b6bf, .count = 2940, .sha256 = "9ad2e5f6ac3bcb07a96fa8502f340eea47cc5e0a5fa89ffadf1d08a009a6e70f" },
    .{ .group = "parallel", .call = 0x9fcc6b4a94451588, .count = 2016, .sha256 = "579ab9e1fbddad00a62b94b408c4c5b5aa1e9836127b1dd95ee7052045cfb20c" },
    .{ .group = "pkh", .call = 0xa80ca91471328eb7, .count = 196, .sha256 = "5ad8089f442a3b626b95a54302f2f7305aae158102244586f08a7f53ebd11da2" },
    .{ .group = "preload", .call = 0xb2099d05280477dc, .count = 1614, .sha256 = "771f2577f608cfa17b119c74f29077f4f53f4d98a2d4ceab3a99e87346541fa7" },
    .{ .group = "push_pop", .call = 0x5815c381715f721b, .count = 1022, .sha256 = "2c141bb849f188c9c8abdebd3a354d1b0414ada4673acd2ceb58d866d316032b" },
    .{ .group = "reverse", .call = 0xfece4ba5e345dfa3, .count = 192, .sha256 = "387ecd35fc7db4be7a56f269db8afc4d9c06abb46aad26fa69b30f3cc77d70b1" },
    .{ .group = "sat16", .call = 0x0fcf778d87c19614, .count = 1568, .sha256 = "ff89809b10697f1fdc20c151d06e238ede3fe75caffc168608aa05c7f0380639" },
    .{ .group = "sat_arith", .call = 0x3eada8cdf1efdd80, .count = 2352, .sha256 = "510b983246a755e4d48bcfe24ec020ead5c3af4874b16caca7af2fa6f2859bee" },
    .{ .group = "saturate", .call = 0x3cf9ed419a1572d5, .count = 16464, .sha256 = "1e314bffc7e7d8e5b0b5596a3a70b44919e15c17ba4fccf65bd54c5b8247dd2e" },
    .{ .group = "sel", .call = 0xd3207d92863f77d1, .count = 392, .sha256 = "1cf494773b828d83fa8185a26d3dcaf9ee0759d679d4336c09c5904cb3ce6f30" },
    .{ .group = "sg", .call = 0xb291a514d1322e0f, .count = 1, .sha256 = "fe00ac3097466f56398dfc699c09dc19e73286e27b4c7c37b84eafb62b6313cd" },
    .{ .group = "shift_imm", .call = 0x7a3bf7b03c9c1361, .count = 6144, .sha256 = "c6d7f04ee5f937964538c0793b7aadded2a465ff52fad345daff2cd284b90bc1" },
    .{ .group = "shift_reg", .call = 0xbf8e53a061495a01, .count = 21952, .sha256 = "ee4bdcdc0530141e9c097ef497ad3f1ad31be5364c216c0a6b7bef5145f94ab2" },
    .{ .group = "sp_arith", .call = 0xdcd713ff6ca2cbb4, .count = 4352, .sha256 = "8314bebb33c524d28d351b5fb98b7a8de909e1f8dc1bb0ca756c53aff1d61a72" },
    .{ .group = "special_data", .call = 0x743aa3f3ee285c39, .count = 703, .sha256 = "12ead8905b6e7834aab933b1f8f96e26124cea68a8f0b02eaf1102c195bde3ad" },
    .{ .group = "svc", .call = 0xc0d620fd0fbf84a2, .count = 256, .sha256 = "69d67b9b4e1960d22638ec3e89e84f6022e7025dd1ec61beb918cb2c30c2b711" },
    .{ .group = "table_branch", .call = 0x39085f0623cac499, .count = 60, .sha256 = "a566357489408d152d8751ae720cbca88fa12cf1fa7ad4f2299837dc7721a67b" },
    .{ .group = "tt", .call = 0xe61fce96c141007e, .count = 90, .sha256 = "5ed07718e8bdcaed02772c3e8975f2bc9ab844fe283940d1b8af242222f91680" },
    .{ .group = "udf", .call = 0x4805d6bbc4ff7ef2, .count = 80, .sha256 = "a63a0c6cfb772ac65ebdc0a2b92979ae4fcccdf7a7ea24a7a1c41e14a4a109fb" },
    .{ .group = "udf", .call = 0x71161a860290ae37, .count = 255, .sha256 = "d91e426ac782a1468503fe410d34cb69e7c95c472aaa88e93395c7935794620f" },
    .{ .group = "umaal", .call = 0xf214392a1dbac74b, .count = 1176, .sha256 = "099df58cec317dd15056f082a5585694c8b02f7bcdf3f2533f6ae6159f2334e7" },
    .{ .group = "usad8", .call = 0x248cd76b0cca8245, .count = 840, .sha256 = "92a80f0dbf545772aedf46d75932c3cfff3f5b1f441cbcc346029e23807a1af4" },
};

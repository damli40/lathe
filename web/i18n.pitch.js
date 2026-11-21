// Pitch and figure copy for the Lathe page. English and Simplified Chinese.
// These strings are final copy. Change wording here only, never in the markup.
// No em dashes. Every number below has a source in /evidence.

export const pitch = {
  en: {
    meta: {
      title: "Lathe: pay only when circuits pass",
      description:
        "Order a TapeOut circuit on X Layer. The contract tests every case and pays the builder only if all of them pass.",
    },
    nav: { how: "How it works", proof: "What we tested", order: "Orders", github: "GitHub" },
    hero: {
      headline: "Pay only when circuits pass.",
      sub: "Paying a circuit builder up front means hoping it works. Lathe holds the money until a contract tests every case.",
      ctaCreate: "Create an order",
      ctaLookup: "Look up an order",
    },
    problem: {
      heading: "Today you pay first and hope.",
      body: "Games and agent wallets on X Layer run their rules on TapeOut circuits. To get one built, you learn NAND design or pay a builder and hope.",
    },
    how: {
      heading: "One order, start to finish",
      steps: [
        {
          title: "Write the table",
          body: "Up to 6 yes/no inputs. You set the expected answer for each of the 64 cases.",
        },
        {
          title: "Lock the payment",
          body: "Your USD₮0 goes into the order contract, with a deadline and the one builder who may deliver.",
        },
        {
          title: "Deliver the circuit",
          body: "The builder mints the circuit on TapeOut and submits its ID.",
        },
        {
          title: "Check every case",
          body: "The contract runs all the cases through the circuit and compares each answer with your table.",
        },
        {
          title: "Pay or refund",
          body: "All answers match and the builder gets paid. If nothing passes by the deadline, you take the money back.",
        },
      ],
    },
    proof: {
      heading: "What we tested",
      items: [
        {
          title: "A real circuit from X Layer mainnet",
          body: "On a copy of mainnet, a 4-gate XOR circuit that someone else minted passed its table and the builder got paid. The same circuit against a wrong table was refused.",
          link: "Read the test",
        },
        {
          title: "A public testnet run, Nov 21 2026",
          body: "We sent 46 transactions to the final contract on X Layer testnet and every one went through. Orders were paid, a late order was refunded, and a 4,096-case check finished in 5 transactions. Testnet has no TapeOut, so these used stand-in circuits.",
          link: "See the transactions",
        },
        {
          title: "328 automated tests",
          body: "239 contract tests, 36 tests on a copy of X Layer mainnet and 53 tests of this page. All pass.",
          link: "Open the evidence folder",
        },
      ],
    },
    limits: {
      heading: "Known limits",
      items: [
        "This page makes tables of up to 6 inputs, so 64 cases. The contract also takes bigger rules split into up to 8 wired pieces, each tested on its own. This page shows those orders but cannot create them yet.",
        "Every order names one builder. Open orders would let anyone copy the honest builder's circuit and deliver it first.",
        "A 3-of-5 multisig owns TapeOut's processor factory and can change it. Lathe records each delivered circuit's gate count and wiring, and refuses to pay if either changes before the check ends. It cannot see a change to the code that runs the circuit.",
        "Lathe has no owner and no admin key. The fee rate is fixed when the contract is deployed and cannot go above 5%.",
      ],
    },
    footer: {
      line: "Built for X Layer TapeOut Accelerate. MIT licence.",
      contract: "Order contract",
      notDeployed: "Not on mainnet yet",
    },
    fig: {
      fig: "Fig 1",
      title: "Order test bench",
      hint: "Click the chip to swap in a faulty one",
      hintFaulty: "Click the chip to put the good one back",
      chipLabel: "Chip under test. Activate to swap between the good and the faulty chip.",
      rLocked: "Payment locked. Waiting for a chip.",
      rChecking: "Case {n} of 64: match",
      rRefused: "Case {n} of 64: wrong answer. Payment held.",
      rPaid: "64 of 64 match. Builder paid.",
      rRefunded: "Deadline passed. Buyer refunded.",
      kCard: "Table card: the buyer's 64 expected answers",
      kChip: "Chip: the builder's circuit",
      kLatch: "Latch: the contract. It opens only on 64 of 64.",
      caption:
        "The switches run every case. The lamp compares each answer with the card. One wrong answer and the coin stays where it is.",
    },
  },

  zh: {
    meta: {
      title: "Lathe：电路通过，才付款",
      description: "在 X Layer 上订购 TapeOut 电路。合约测试每一种输入，全部通过才付款给开发者。",
    },
    nav: { how: "流程", proof: "测试记录", order: "订单", github: "GitHub" },
    hero: {
      headline: "电路通过，才付款。",
      sub: "先付款给电路开发者，只能指望电路能用。Lathe 把钱锁在合约里，等合约测完每一种输入再放款。",
      ctaCreate: "创建订单",
      ctaLookup: "查询订单",
    },
    problem: {
      heading: "现在的做法是先付钱，再碰运气。",
      body: "X Layer 上的游戏和智能体钱包用 TapeOut 电路执行规则。想要一个电路，要么自己学 NAND 设计，要么先付钱给开发者，再指望它能用。",
    },
    how: {
      heading: "一笔订单的全过程",
      steps: [
        {
          title: "填写真值表",
          body: "最多 6 个是/否输入。你为 64 种情况逐一填好期望的输出。",
        },
        {
          title: "锁定款项",
          body: "你的 USD₮0 进入订单合约，同时设定截止时间，并指定唯一可以交付的开发者。",
        },
        {
          title: "交付电路",
          body: "开发者在 TapeOut 上铸造电路，并提交电路编号。",
        },
        {
          title: "逐项检查",
          body: "合约把所有情况输入电路，把每个输出和你的真值表对比。",
        },
        {
          title: "付款或退款",
          body: "全部一致，开发者收到款项。截止时间前没有电路通过，你可以取回资金。",
        },
      ],
    },
    proof: {
      heading: "测试记录",
      items: [
        {
          title: "X Layer 主网上的真实电路",
          body: "在主网的副本上，一个由他人铸造的 4 门 XOR 电路通过了真值表，开发者收到款项。同一个电路对上错误的真值表，合约拒绝付款。",
          link: "查看测试",
        },
        {
          title: "公开测试网运行，2026 年 11 月 21 日",
          body: "我们向 X Layer 测试网上的最终版合约发送了 46 笔交易，全部成功。订单完成付款，一笔逾期订单已退款，一次 4,096 种情况的检查用 5 笔交易完成。测试网没有 TapeOut，所以用的是替代电路。",
          link: "查看交易",
        },
        {
          title: "328 项自动化测试",
          body: "239 项合约测试，36 项在 X Layer 主网副本上运行的测试，53 项本页面测试，全部通过。",
          link: "打开证据目录",
        },
      ],
    },
    limits: {
      heading: "已知限制",
      items: [
        "本页面可创建最多 6 个输入的真值表，也就是 64 种情况。合约还支持把更大的规则拆成最多 8 个连线部分，每个部分单独测试。本页面可以显示这类订单，但暂时不能创建。",
        "每笔订单指定一位开发者。开放订单会让任何人复制诚实开发者的电路并抢先交付。",
        "TapeOut 的处理器工厂由 3/5 多签持有，多签可以修改它。Lathe 会记录交付电路的门数和连线，检查结束前任何一项有变动，就拒绝付款。运行电路的代码如果被改动，Lathe 无法察觉。",
        "Lathe 没有所有者，也没有管理员密钥。费率在部署时固定，最高 5%。",
      ],
    },
    footer: {
      line: "为 X Layer TapeOut Accelerate 而建。MIT 许可证。",
      contract: "订单合约",
      notDeployed: "尚未部署到主网",
    },
    fig: {
      fig: "图 1",
      title: "订单测试台",
      hint: "点击芯片，换上一块有问题的",
      hintFaulty: "点击芯片，换回正常的那块",
      chipLabel: "被测芯片。点击可在正常芯片和问题芯片之间切换。",
      rLocked: "款项已锁定，等待芯片。",
      rChecking: "第 {n} / 64 种情况：一致",
      rRefused: "第 {n} / 64 种情况：输出错误，款项不放。",
      rPaid: "64 / 64 全部一致，开发者已收款。",
      rRefunded: "已过截止时间，买家已退款。",
      kCard: "真值卡：买家填写的 64 个期望输出",
      kChip: "芯片：开发者交付的电路",
      kLatch: "锁扣：合约。只有 64 / 64 才会打开。",
      caption: "开关依次跑完每一种情况，指示灯把每个输出和真值卡对比。只要有一个输出错误，硬币就留在原处。",
    },
  },
};

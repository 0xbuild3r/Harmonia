// test/Router.test.js

const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Router Contract with MockLido", function () {
  let Router, MockLido, stETH, MockWithdrawalQueue;
  let owner, routerManager, otherUser;

  beforeEach(async function () {
    [owner, routerManager, otherUser] = await ethers.getSigners();

    // Deploy MockLido
    const MockLidoFactory = await ethers.getContractFactory("MockLido");
    MockLido = await MockLidoFactory.connect(owner).deploy();
    await MockLido.deployed();
    //console.log("MockLido deployed at:", MockLido.address);
  
    // Get the deployed stETH token from MockLido
    const stETHAddress = await MockLido.stETH();
    const MockSTETHFactory = await ethers.getContractFactory("MockSTETH");
    stETH = MockSTETHFactory.attach(stETHAddress)

    // Deploy MockWithdrawalQueue
    const MockWithdrawalQueueFactory = await ethers.getContractFactory("MockWithdrawalQueue");
    MockWithdrawalQueue = await MockWithdrawalQueueFactory.connect(owner).deploy(stETHAddress, MockLido.address);
    await MockWithdrawalQueue.deployed();

    // Deploy BetaRouter
    const RouterFactory = await ethers.getContractFactory("Router");
    Router = await RouterFactory.connect(owner).deploy(MockLido.address, MockWithdrawalQueue.address, routerManager.address);
    await Router.deployed();
    //console.log("Router deployed at:", Router.address);
  });

  
  it("Should allow routerManager to deposit ETH and receive shares in MockLido", async function () {
    const depositAmount = ethers.utils.parseEther("1");
    await Router.connect(routerManager).deposit({ value: depositAmount });

    // Check Router's balance in MockLido
    const routerShares = await stETH.balanceOf(Router.address);
    expect(routerShares).to.equal(depositAmount); // Initial exchange rate is 1:1
  });
  
  it("Should update stETH balance after rebasing", async function () {
    const depositAmount = ethers.utils.parseEther("10");
    await Router.connect(routerManager).deposit({ value: depositAmount });
    const totalETHBefore = await MockLido.getTotalPooledEther();

    // Simulate earnings in MockLido
    const profitAmount = ethers.utils.parseEther("1"); // 1 ETH profit
    await MockLido.connect(routerManager).rebase(profitAmount, routerManager.address);

    // Check Router's stETH balance
    const totalETHAfter = await MockLido.getTotalPooledEther();
    const routerBalance = depositAmount.mul(totalETHAfter).div(totalETHBefore);

    // Verify that Router's balance increased
    expect(routerBalance).to.equal(depositAmount.add(profitAmount));
  });

  it("Should update stETH balance after loss", async function () {
    const depositAmount = ethers.utils.parseEther("10");
    await Router.connect(routerManager).deposit({ value: depositAmount });
    const totalETHBefore = await MockLido.getTotalPooledEther();

    // Simulate loss in MockLido
    const lossAmount = ethers.utils.parseEther("2"); // 2 ETH loss
    await MockLido.connect(owner).reportLoss(lossAmount);

    // Check Router's stETH balance
    const totalETHAfter = await MockLido.getTotalPooledEther();
    const routerBalance = depositAmount.mul(totalETHAfter).div(totalETHBefore);

    // Verify that Router's balance decreased
    expect(routerBalance).to.equal(depositAmount.sub(lossAmount));
  });

  it("Should fail to deposit zero ETH", async function () {
    await expect(
      Router.connect(routerManager).deposit({ value: 0 })
    ).to.be.revertedWith("Must deposit ETH");
  });

  it("Should allow routerManager to request withdrawal", async function () {
    const depositAmount = ethers.utils.parseEther("2");
    const withdrawalAmount = ethers.utils.parseEther("1");

    await Router.connect(routerManager).deposit({ value: depositAmount });
    const tx = await Router.connect(routerManager).requestWithdrawal(await routerManager.getAddress(), withdrawalAmount);
    const receipt = await tx.wait();
    const requestId = receipt.events.find((x) => x.event === "WithdrawalRequested").args.requestId;

    expect(requestId).to.not.be.undefined;

    //const userBalance = await Router.userBalances(await routerManager.getAddress());
    //expect(userBalance).to.equal(depositAmount.sub(withdrawalAmount));

    const totalDepositedETH = await Router.getTotalDepositedETH();
    expect(totalDepositedETH).to.equal(depositAmount.sub(withdrawalAmount));
  });

  it("Should fail to request withdrawal with zero amount", async function () {
    await expect(
      Router.connect(routerManager).requestWithdrawal(await routerManager.getAddress(), 0)
    ).to.be.revertedWith("Amount must be greater than zero");
  });
  
  it("Should fail to request withdrawal exceeding routerManager's balance", async function () {
    const depositAmount = ethers.utils.parseEther("1"); // 1 ETH
    const withdrawalAmount = ethers.utils.parseEther("2"); // 2 ETH

    await Router.connect(routerManager).deposit({ value: depositAmount });

    await expect(
      Router.connect(routerManager).requestWithdrawal(await routerManager.getAddress(), withdrawalAmount)
    ).to.be.revertedWith("Insufficient stETH balance");
  });
  
  it("Should allow routerManager to claim finalized withdrawal", async function () {
    const depositAmount = ethers.utils.parseEther("2");
    const withdrawalAmount = ethers.utils.parseEther("1");
    const begienningBalance = await routerManager.getBalance();

    await Router.connect(routerManager).deposit({ value: depositAmount });
    const tx = await Router.connect(routerManager).requestWithdrawal(await routerManager.getAddress(), withdrawalAmount);
    const receipt = await tx.wait();
    const requestId = receipt.events.find((x) => x.event === "WithdrawalRequested").args.requestId;

    // Finalize withdrawal in MockLido
    await MockWithdrawalQueue.connect(owner).finalizeWithdrawal(requestId);

    // routerManager claims withdrawal
    const initialBalance = await routerManager.getBalance();
    const tx2 = await Router.connect(routerManager).claimWithdrawal(requestId, routerManager.address);
    const receipt2 = await tx2.wait();
    const gasUsed = receipt2.gasUsed.mul(receipt2.effectiveGasPrice);
    const finalBalance = await routerManager.getBalance();
    console.log(await routerManager.getAddress(), routerManager.address);
    console.log(begienningBalance/1e18, initialBalance /1e18, finalBalance/1e18);

    // Verify that the routerManager received the ETH back (accounting for gas used)
    expect(finalBalance).to.be.closeTo(
      initialBalance.sub(gasUsed).add(withdrawalAmount),
      ethers.utils.parseEther("0.01")
    );
  });

  it("Should fail to claim withdrawal that is not finalized", async function () {
    const depositAmount = ethers.utils.parseEther("2");
    const withdrawalAmount = ethers.utils.parseEther("1");

    await Router.connect(routerManager).deposit({ value: depositAmount });
    const tx = await Router.connect(routerManager).requestWithdrawal(await routerManager.getAddress(), withdrawalAmount);
    const receipt = await tx.wait();
    const requestId = receipt.events.find((x) => x.event === "WithdrawalRequested").args.requestId;

    // Attempt to claim withdrawal before it's finalized
    await expect(
      Router.connect(routerManager).claimWithdrawal(requestId, routerManager.address)
    ).to.be.revertedWith("Withdrawal not finalized");
  });

  it("Should fail to claim withdrawal with invalid requestId", async function () {
    const invalidRequestId = 9999;
    await expect(
      Router.connect(routerManager).claimWithdrawal(invalidRequestId,routerManager.address)
    ).to.be.reverted;
  });

  it("Should fail to claim withdrawal if caller is not the requester", async function () {
    const depositAmount = ethers.utils.parseEther("2");
    const withdrawalAmount = ethers.utils.parseEther("1");

    await Router.connect(routerManager).deposit({ value: depositAmount });
    const tx = await Router.connect(routerManager).requestWithdrawal(await routerManager.getAddress(), withdrawalAmount);
    const receipt = await tx.wait();
    const requestId = receipt.events.find((x) => x.event === "WithdrawalRequested").args.requestId;

    // Finalize withdrawal in MockLido
    await MockWithdrawalQueue.connect(owner).finalizeWithdrawal(requestId);

    // Other routerManager attempts to claim withdrawal
    await expect(
      Router.connect(otherUser).claimWithdrawal(requestId, otherUser.address)
    ).to.be.revertedWith("Caller is not RouterManager");
  });
  
  it("Should correctly report whether a withdrawal is finalized", async function () {
    const depositAmount = ethers.utils.parseEther("2");
    const withdrawalAmount = ethers.utils.parseEther("1");

    await Router.connect(routerManager).deposit({ value: depositAmount });
    const tx = await Router.connect(routerManager).requestWithdrawal(await routerManager.getAddress(), withdrawalAmount);
    const receipt = await tx.wait();
    const requestId = receipt.events.find((x) => x.event === "WithdrawalRequested").args.requestId;

    // Check if withdrawal is finalized (should be false)
    let isFinalized = await MockWithdrawalQueue.isWithdrawalFinalized(requestId);
    expect(isFinalized).to.be.false;

    // Finalize withdrawal in MockLido
    await MockWithdrawalQueue.connect(owner).finalizeWithdrawal(requestId);

    // Check again (should be true)
    isFinalized = await MockWithdrawalQueue.isWithdrawalFinalized(requestId);
    expect(isFinalized).to.be.true;
  });
  
  it("Should have the correct initial admin fee", async function () {
    const adminFee = await Router.adminFeePercent();
    expect(adminFee).to.equal(1000); // 1%
  });

  it("Admin can update the admin fee within the allowed range", async function () {
    const newAdminFee = 2000; // 2%
    await Router.connect(owner).setAdminFeePercent(newAdminFee);
    const updatedAdminFee = await Router.adminFeePercent();
    expect(updatedAdminFee).to.equal(newAdminFee);
  });

  it("Admin cannot set the admin fee above the maximum allowed", async function () {
    const excessiveAdminFee = 12000; // 12%, exceeds MAX_ADMIN_FEE of 10%
    await expect(
      Router.connect(owner).setAdminFeePercent(excessiveAdminFee)
    ).to.be.revertedWith("Admin fee exceeds maximum limit");
  });

  it("Non-admin cannot set the admin fee", async function () {
    const newAdminFee = 2000; // 2%
    await expect(
      Router.connect(routerManager).setAdminFeePercent(newAdminFee)
    ).to.be.reverted;
  });
  

  it("Should correctly handle admin fees after stETH accrues", async function () {
    const firstDeposit = ethers.utils.parseEther("10"); // 10 ETH
    const secondDeposit = ethers.utils.parseEther("10"); // 10 ETH
    const adminFeeBasisPoints = 1000; // 1%

    // routerManager makes the first deposit
    await Router.connect(routerManager).deposit({ value: firstDeposit });

    // Simulate earnings in MockLido
    const rebaseAmount = ethers.utils.parseEther("1"); // 1 ETH profit
    await MockLido.connect(routerManager).rebase(rebaseAmount, Router.address);
    
    // Check initial admin fees
    const initialAdminFees = await Router.getAccruedAdminFees();
    const expectedInitialFee = rebaseAmount.mul(adminFeeBasisPoints).div(100_000); // 0.01 ETH
    expect(initialAdminFees).to.equal(expectedInitialFee);

    // Total staked should now be firstDeposit - firstFee + profit
    const totalStaked = await Router.getStETHBalance();
    const expectedTotalStaked = firstDeposit.sub(expectedInitialFee).add(rebaseAmount);
    expect(totalStaked).to.equal(expectedTotalStaked);

    // Simulate earnings in MockLido
    await MockLido.connect(routerManager).rebase(rebaseAmount, Router.address);    

    // routerManager makes the second deposit
    await Router.connect(routerManager).deposit({ value: secondDeposit });

    // Calculate expected admin fee for the second deposit
    const expectedSecondFee = rebaseAmount.mul(adminFeeBasisPoints).div(100_000); // 0.01 ETH
    const expectedTotalFees = initialAdminFees.add(expectedSecondFee);
    expect(await Router.getAccruedAdminFees() / 1e18).to.equal(expectedTotalFees/ 1e18);

    // Admin withdraws accumulated fees 
    await Router.connect(owner).withdrawAdminFees();

    // Accumulated admin fees should reset
    expect(await Router.accumulatedAdminFees()).to.equal(0);

    // Routers balance reflect the rebase
    expect(await Router.getStETHBalance()).to.equal(ethers.utils.parseEther("21.98"));

    // Admin's stETH balance should increase by expectedTotalFees minus gas used
    expect(await stETH.balanceOf(owner.address)).to.equal(expectedTotalFees);
    
    // Simulate earnings in MockLido
    await MockLido.connect(routerManager).rebase(rebaseAmount, Router.address);    

    //current balance

    const totalHoldings = await Router.getStETHBalance();

    //withdrawal request increases accumulated fees
    await Router.connect(routerManager).requestWithdrawal(await routerManager.getAddress(), totalHoldings);
    expect(await Router.accumulatedAdminFees()).to.not.equal(0);
  });

});


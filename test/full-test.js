const { expect } = require("chai");
const { ethers, network } = require("hardhat");
const { time, loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

// This check ensures the entire suite is only run on the local Hardhat network.
if (network.name !== "hardhat") {
    describe("Mata Estate Planning Protocol (Full Suite)", function () {
        it("should only run on the Hardhat network", function () {
            console.error("This comprehensive test suite is designed to run only on the `hardhat` network.");
            console.error("Please run `npx hardhat test` without any --network flags.");
            this.skip();
        });
    });
} else {
    describe("Mata Estate Planning Protocol (Full Suite)", function () {
        this.timeout(60000);

        // --- Constants ---
        const DIARY_PLATFORM_FEE = ethers.parseEther("0.3");
        const WILL_ETH_VALUE = ethers.parseEther("1.0");
        const INACTIVITY_INTERVAL = 30 * 24 * 60 * 60;
        const EXECUTOR_ADDRESS = "0x06E5b15Bc39f921e1503073dBb8A5dA2Fc6220E9";
        const EXECUTOR_WINDOW = 1 * 24 * 60 * 60;

        // --- Main Deployment Fixture ---
        async function deployContractsFixture() {
            const signers = await ethers.getSigners();
            const [
                _owner, testator, heir1, heir2, publicExecutor, otherUser,
                coFounderOnePri, coFounderOneSec, coFounderTwoPri, coFounderTwoSec,
                newPri, newSec, newExecutorSigner
            ] = signers;

            await network.provider.request({ method: "hardhat_impersonateAccount", params: [EXECUTOR_ADDRESS] });
            await _owner.sendTransaction({ to: EXECUTOR_ADDRESS, value: ethers.parseEther("10") });
            const executor = await ethers.getSigner(EXECUTOR_ADDRESS);

            const MockERC20 = await ethers.getContractFactory("MockERC20");
            const mockERC20 = await MockERC20.deploy();
            const mockERC20Address = await mockERC20.getAddress();

            const MockERC721 = await ethers.getContractFactory("MockERC721");
            const mockERC721 = await MockERC721.deploy();
            const mockERC721Address = await mockERC721.getAddress();

            await mockERC20.connect(_owner).transfer(testator.address, ethers.parseEther("1000"));
            await mockERC721.connect(_owner).mint(testator.address, 1);
            await mockERC721.connect(_owner).mint(testator.address, 2);

            const Source = await ethers.getContractFactory("Source");
            const source = await Source.deploy(
                coFounderOnePri.address, coFounderOneSec.address,
                coFounderTwoPri.address, coFounderTwoSec.address,
                EXECUTOR_ADDRESS
            );

            const Will = await ethers.getContractFactory("Will");

            return {
                source, Will, mockERC20, mockERC721, testator, heir1, heir2, executor,
                publicExecutor, otherUser, coFounderOnePri, coFounderOneSec, coFounderTwoPri,
                coFounderTwoSec, newPri, newSec, newExecutorSigner, mockERC20Address, mockERC721Address
            };
        }

        describe("Source Contract (Factory)", function () {
            
            describe("Governance and Permissions", function () {
                it("should initialize with the correct co-founder and executor addresses", async function () {
                    const { source, coFounderOnePri, coFounderTwoPri } = await loadFixture(deployContractsFixture);
                    const cf1 = await source.coFounderOne();
                    expect(cf1.primary).to.equal(coFounderOnePri.address);
                    const cf2 = await source.coFounderTwo();
                    expect(cf2.primary).to.equal(coFounderTwoPri.address);
                    expect(await source.executorAddress()).to.equal(EXECUTOR_ADDRESS);
                });

                it("should allow any co-founder or the executor to set the diary fee", async function () {
                    const { source, coFounderOnePri, executor, otherUser } = await loadFixture(deployContractsFixture);
                    const newFee = ethers.parseEther("0.5");
                    await expect(source.connect(coFounderOnePri).setDiaryPlatformFee(newFee)).to.not.be.reverted;
                    await expect(source.connect(executor).setDiaryPlatformFee(0)).to.not.be.reverted;
                    await expect(source.connect(otherUser).setDiaryPlatformFee(newFee)).to.be.revertedWith("Source: Caller cannot set diary fee");
                });

                it("should allow co-founders to update their own addresses", async function() {
                    const { source, coFounderOnePri, newPri, newSec, otherUser } = await loadFixture(deployContractsFixture);
                    await source.connect(coFounderOnePri).updateCoFounderOneAddresses(newPri.address, newSec.address);
                    const cf1 = await source.coFounderOne();
                    expect(cf1.primary).to.equal(newPri.address);
                    await expect(source.connect(otherUser).updateCoFounderOneAddresses(newPri.address, newSec.address))
                        .to.be.revertedWith("Source: Caller is not Co-Founder One");
                });
            });

            describe("Executor Management", function() {
                it("should allow a co-founder to change the executor address", async function() {
                    const { source, coFounderTwoSec, newExecutorSigner } = await loadFixture(deployContractsFixture);
                    await expect(source.connect(coFounderTwoSec).setExecutorAddress(newExecutorSigner.address)).to.not.be.reverted;
                    expect(await source.executorAddress()).to.equal(newExecutorSigner.address);
                });

                it("should NOT allow a non-founder to change the executor address", async function() {
                    const { source, otherUser, newExecutorSigner } = await loadFixture(deployContractsFixture);
                    await expect(source.connect(otherUser).setExecutorAddress(newExecutorSigner.address))
                        .to.be.revertedWith("Source: Caller is not a co-founder");
                });

                it("should apply the new executor address only to new wills", async function() {
                    const { source, testator, heir1, Will, executor, newExecutorSigner, coFounderOnePri } = await loadFixture(deployContractsFixture);
                    
                    await source.connect(testator).createWill([heir1.address], [100], INACTIVITY_INTERVAL, [], [], false, { value: WILL_ETH_VALUE });
                    const oldWillAddress = await source.userWills(testator.address);
                    const oldWillContract = Will.attach(oldWillAddress);
                    expect(await oldWillContract.executorAddress()).to.equal(executor.address);

                    await source.connect(coFounderOnePri).setExecutorAddress(newExecutorSigner.address);
                    
                    await oldWillContract.connect(testator).cancelAndWithdraw();
                    await source.connect(testator).createWill([heir1.address], [100], INACTIVITY_INTERVAL, [], [], false, { value: WILL_ETH_VALUE });
                    const newWillAddress = await source.userWills(testator.address);
                    const newWillContract = Will.attach(newWillAddress);

                    expect(await newWillContract.executorAddress()).to.equal(newExecutorSigner.address);
                    expect(await oldWillContract.executorAddress()).to.equal(executor.address);
                });
            });

            describe("Fee Withdrawal and Will Creation", function() {
                it("should split fees 90/10 and pay both founders", async function() {
                    const { source, testator, heir1, coFounderOnePri, coFounderTwoPri } = await loadFixture(deployContractsFixture);
                    await source.connect(testator).createWill([heir1.address], [100], INACTIVITY_INTERVAL, [], [], true, { value: DIARY_PLATFORM_FEE });
                    
                    const cf1Initial = await ethers.provider.getBalance(coFounderOnePri.address);
                    const cf2Initial = await ethers.provider.getBalance(coFounderTwoPri.address);

                    // The initiator is coFounderTwoPri
                    await source.connect(coFounderTwoPri).withdrawFees();

                    const expectedShare1 = (DIARY_PLATFORM_FEE * 90n) / 100n;
                    const expectedShare2 = DIARY_PLATFORM_FEE - expectedShare1;

                    // The passive recipient's balance is exact
                    expect(await ethers.provider.getBalance(coFounderOnePri.address)).to.equal(cf1Initial + expectedShare1);
                    
                    // CORRECTED: The initiator's balance is close to the expected value, accounting for gas fees
                    expect(await ethers.provider.getBalance(coFounderTwoPri.address))
                        .to.be.closeTo(cf2Initial + expectedShare2, ethers.parseEther("0.001"));
                });
                
                it("should create a simple will with no platform fee", async function() {
                    const { source, testator, heir1, Will } = await loadFixture(deployContractsFixture);
                    await source.connect(testator).createWill([heir1.address], [100], INACTIVITY_INTERVAL, [], [], false, { value: WILL_ETH_VALUE });
                    const willAddress = await source.userWills(testator.address);
                    const willContract = Will.attach(willAddress);
                    expect(await willContract.terminationFee()).to.equal(0);
                    expect(await ethers.provider.getBalance(willAddress)).to.equal(WILL_ETH_VALUE);
                });
            });
        });

        describe("Will Contract Execution", function () {
            async function createStandardWillFixture() {
                const base = await loadFixture(deployContractsFixture);
                const sourceAddress = await base.source.getAddress();
                await base.mockERC20.connect(base.testator).approve(sourceAddress, ethers.parseEther("100"));
                await base.source.connect(base.testator).createWill(
                    [base.heir1.address], [100], INACTIVITY_INTERVAL,
                    [{ tokenContract: base.mockERC20Address, amount: ethers.parseEther("100") }], [],
                    true, { value: WILL_ETH_VALUE + DIARY_PLATFORM_FEE }
                );
                const willAddress = await base.source.userWills(base.testator.address);
                const willContract = base.Will.attach(willAddress);
                return { ...base, willAddress, willContract };
            }
            
            it("should direct execution fee to Source contract when called by executor", async function () {
                const { willContract, executor, source } = await loadFixture(createStandardWillFixture);
                await time.increase(INACTIVITY_INTERVAL + 100);

                const sourceInitialBalance = await ethers.provider.getBalance(await source.getAddress());
                await willContract.connect(executor).execute();
                const fee = (WILL_ETH_VALUE * 50n) / 10000n;
                expect(await ethers.provider.getBalance(await source.getAddress())).to.equal(sourceInitialBalance + fee);
            });

            it("should direct execution fee to msg.sender when called by public", async function() {
                const { willContract, publicExecutor } = await loadFixture(createStandardWillFixture);
                await time.increase(INACTIVITY_INTERVAL + EXECUTOR_WINDOW + 100);

                const publicExecutorInitialBalance = await ethers.provider.getBalance(publicExecutor.address);
                const tx = await willContract.connect(publicExecutor).execute();
                const receipt = await tx.wait();
                const gasUsed = receipt.gasUsed * receipt.gasPrice;

                const fee = (WILL_ETH_VALUE * 50n) / 10000n;
                expect(await ethers.provider.getBalance(publicExecutor.address))
                    .to.be.closeTo(publicExecutorInitialBalance + fee - gasUsed, ethers.parseEther("0.01"));
            });
        });
    });
}
// test/full-test.j
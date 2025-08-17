const { expect } = require("chai");
const { ethers, network } = require("hardhat");
const { time, loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

// This check ensures the entire suite is only run on the local Hardhat network.
if (network.name !== "hardhat") {
    describe("Mata Estate Planning Protocol (Full Suite)", function () {
        it("should only run on the Hardhat network", function () {
            console.error("This comprehensive test suite is designed to run only on the `hardhat` network.");
            console.error("Please run `npx hardhat test` without any --network flags.");
            this.skip(); // Skips the rest of the tests in a clean way.
        });
    });
} else {
    describe("Mata Estate Planning Protocol (Full Suite)", function () {
        this.timeout(60000); // 60 seconds

        // --- Constants ---
        const BASE_PLATFORM_FEE = ethers.parseEther("0.1");
        const DIARY_PLATFORM_FEE = ethers.parseEther("0.3");
        const WILL_ETH_VALUE = ethers.parseEther("1.0");
        const INACTIVITY_INTERVAL = 30 * 24 * 60 * 60; // 30 days
        const EXECUTOR_ADDRESS = "0xa9F8F9C0bf3188cEDdb9684ae28655187552bAE9";
        const EXECUTOR_WINDOW = 1 * 24 * 60 * 60; // 1 day

        // --- Main Deployment Fixture ---
        async function deployContractsFixture() {
            const signers = await ethers.getSigners();
            const [owner, testator, heir1, heir2, publicExecutor, otherUser] = signers;

            await network.provider.request({ method: "hardhat_impersonateAccount", params: [EXECUTOR_ADDRESS] });
            await owner.sendTransaction({ to: EXECUTOR_ADDRESS, value: ethers.parseEther("10") });
            const executor = await ethers.getSigner(EXECUTOR_ADDRESS);

            const MockERC20 = await ethers.getContractFactory("MockERC20");
            const mockERC20 = await MockERC20.deploy();
            const mockERC20Address = await mockERC20.getAddress();

            const MockERC721 = await ethers.getContractFactory("MockERC721");
            const mockERC721 = await MockERC721.deploy();
            const mockERC721Address = await mockERC721.getAddress();

            await mockERC20.connect(owner).transfer(testator.address, ethers.parseEther("1000"));
            await mockERC721.connect(owner).mint(testator.address, 1);
            await mockERC721.connect(owner).mint(testator.address, 2);
            await mockERC721.connect(owner).mint(testator.address, 3);

            const Source = await ethers.getContractFactory("Source");
            const source = await Source.deploy(owner.address);
            await source.connect(owner).setBasePlatformFee(BASE_PLATFORM_FEE);
            await source.connect(owner).setDiaryPlatformFee(DIARY_PLATFORM_FEE);

            const Will = await ethers.getContractFactory("Will");

            return {
                source, Will, mockERC20, mockERC721, owner, testator, heir1, heir2,
                executor, publicExecutor, otherUser, mockERC20Address, mockERC721Address
            };
        }

        // ===============================================================================================
        //                                      TEST SUITES
        // ===============================================================================================

        describe("Source Contract (Factory)", function () {
            describe("Core Functionality", function () {
                it("should set the correct owner and initial fees", async function () {
                    const { source, owner } = await loadFixture(deployContractsFixture);
                    expect(await source.owner()).to.equal(owner.address);
                    expect(await source.basePlatformFee()).to.equal(BASE_PLATFORM_FEE);
                    expect(await source.diaryPlatformFee()).to.equal(DIARY_PLATFORM_FEE);
                });
            });

            describe("Fee Management", function () {
                it("should allow the owner to change platform fees", async function () {
                    const { source, owner } = await loadFixture(deployContractsFixture);
                    await source.connect(owner).setBasePlatformFee(ethers.parseEther("0.5"));
                    expect(await source.basePlatformFee()).to.equal(ethers.parseEther("0.5"));
                });

                it("should prevent non-owners from changing platform fees", async function () {
                    const { source, otherUser } = await loadFixture(deployContractsFixture);
                    await expect(source.connect(otherUser).setBasePlatformFee(ethers.parseEther("1")))
                        .to.be.revertedWithCustomError(source, "OwnableUnauthorizedAccount");
                });

                it("should allow the owner to withdraw fees", async function () {
                    const { source, owner, testator } = await loadFixture(deployContractsFixture);
                    await testator.sendTransaction({ to: await source.getAddress(), value: ethers.parseEther("1") });
                    const initialOwnerBalance = await ethers.provider.getBalance(owner.address);
                    const tx = await source.connect(owner).withdrawFees();
                    const receipt = await tx.wait();
                    const gasUsed = receipt.gasUsed * receipt.gasPrice;
                    const finalOwnerBalance = await ethers.provider.getBalance(owner.address);
                    expect(finalOwnerBalance).to.be.closeTo(initialOwnerBalance + ethers.parseEther("1") - gasUsed, ethers.parseEther("0.001"));
                });

                 it("should revert withdrawing fees when balance is zero", async function () {
                    const { source, owner } = await loadFixture(deployContractsFixture);
                    await expect(source.connect(owner).withdrawFees()).to.be.revertedWith("No fees to withdraw.");
                });
            });

            describe("Will Creation Scenarios", function() {
                it("should create a standard will (no diary) successfully", async function() {
                    const { source, testator, heir1 } = await loadFixture(deployContractsFixture);
                    const creationValue = WILL_ETH_VALUE + BASE_PLATFORM_FEE;
                    await expect(source.connect(testator).createWill(
                        [heir1.address], [100], INACTIVITY_INTERVAL, [], [], false,
                        { value: creationValue }
                    )).to.not.be.reverted;
                    const willAddress = await source.userWills(testator.address);
                    expect(willAddress).to.be.properAddress;
                });

                it("should create a will WITH a diary successfully", async function() {
                    const { source, testator, heir1, Will } = await loadFixture(deployContractsFixture);
                    const creationValue = WILL_ETH_VALUE + DIARY_PLATFORM_FEE;
                    await source.connect(testator).createWill(
                        [heir1.address], [100], INACTIVITY_INTERVAL, [], [], true,
                        { value: creationValue }
                    );
                    const willAddress = await source.userWills(testator.address);
                    const willContract = Will.attach(willAddress);
                    expect(await willContract.hasDiary()).to.be.true;
                    expect(await willContract.terminationFee()).to.equal(DIARY_PLATFORM_FEE);
                });
            });
            
            describe("Will Creation Failure Cases", function () {
                it("should revert if ETH sent is less than the required fee", async function () {
                    const { source, testator } = await loadFixture(deployContractsFixture);
                    await expect(source.connect(testator).createWill([], [], 0, [], [], false, { value: ethers.parseEther("0.01") }))
                        .to.be.revertedWith("Msg.value must cover the required platform fee.");
                });

                it("should revert if a user tries to create a second will", async function () {
                    const { source, testator, heir1 } = await loadFixture(deployContractsFixture);
                    await source.connect(testator).createWill([heir1.address], [100], INACTIVITY_INTERVAL, [], [], false, { value: BASE_PLATFORM_FEE });
                    await expect(source.connect(testator).createWill([heir1.address], [100], INACTIVITY_INTERVAL, [], [], false, { value: BASE_PLATFORM_FEE }))
                        .to.be.revertedWith("User already has an existing will.");
                });

                it("should revert if distribution percentages do not sum to 100", async function() {
                    const { source, testator, heir1 } = await loadFixture(deployContractsFixture);
                    await expect(source.connect(testator).createWill([heir1.address], [99], INACTIVITY_INTERVAL, [], [], false, { value: BASE_PLATFORM_FEE }))
                        .to.be.revertedWith("Distribution percentages must sum to 100.");
                });

                it("should revert if there are no heirs", async function() {
                    const { source, testator } = await loadFixture(deployContractsFixture);
                    await expect(source.connect(testator).createWill([], [], INACTIVITY_INTERVAL, [], [], false, { value: BASE_PLATFORM_FEE }))
                        .to.be.revertedWith("Heirs cannot be empty.");
                });

                it("should revert if token transfers are not approved", async function() {
                    const { source, testator, heir1, mockERC20, mockERC20Address } = await loadFixture(deployContractsFixture);
                    const erc20s = [{ tokenContract: mockERC20Address, amount: ethers.parseEther("1") }];
                    await expect(source.connect(testator).createWill(
                        [heir1.address], [100], INACTIVITY_INTERVAL, erc20s, [], false,
                        { value: BASE_PLATFORM_FEE }
                    )).to.be.revertedWithCustomError(mockERC20, "ERC20InsufficientAllowance");
                });
            });
        });

        // ===============================================================================================

        describe("Will Contract Lifecycle", function () {
            async function createStandardWillFixture() {
                const base = await loadFixture(deployContractsFixture);
                const sourceAddress = await base.source.getAddress();
                await base.mockERC20.connect(base.testator).approve(sourceAddress, ethers.parseEther("100"));
                await base.mockERC721.connect(base.testator).approve(sourceAddress, 1);
                await base.mockERC721.connect(base.testator).approve(sourceAddress, 2);

                const erc20s = [{ tokenContract: base.mockERC20Address, amount: ethers.parseEther("100") }];
                const nfts = [
                    { tokenContract: base.mockERC721Address, tokenId: 1, heir: base.heir1.address },
                    { tokenContract: base.mockERC721Address, tokenId: 2, heir: base.heir2.address }
                ];
                const creationValue = WILL_ETH_VALUE + BASE_PLATFORM_FEE;
                await base.source.connect(base.testator).createWill(
                    [base.heir1.address, base.heir2.address], [60, 40], INACTIVITY_INTERVAL,
                    erc20s, nfts, false, { value: creationValue }
                );
                const willAddress = await base.source.userWills(base.testator.address);
                const willContract = base.Will.attach(willAddress);
                return { ...base, willAddress, willContract };
            }

            describe("Creation and State", function () {
                it("should transfer all assets to the will contract upon creation", async function () {
                    const { willAddress, mockERC20, mockERC721 } = await loadFixture(createStandardWillFixture);
                    expect(await ethers.provider.getBalance(willAddress)).to.equal(WILL_ETH_VALUE);
                    expect(await mockERC20.balanceOf(willAddress)).to.equal(ethers.parseEther("100"));
                    expect(await mockERC721.ownerOf(1)).to.equal(willAddress);
                    expect(await mockERC721.ownerOf(2)).to.equal(willAddress);
                });
                
                it("should have correct state variables upon creation", async function () {
                    const { willContract, testator, heir1, heir2 } = await loadFixture(createStandardWillFixture);
                    const details = await willContract.getWillDetails();
                    expect(details.owner).to.equal(testator.address);
                    expect(details.interval).to.equal(INACTIVITY_INTERVAL);
                    expect(details.executed).to.be.false;
                    expect(details.hasDiary).to.be.false;
                    expect(details.heirs).to.deep.equal([heir1.address, heir2.address]);
                    expect(details.distributionPercentages).to.deep.equal([60n, 40n]);
                });
            });

            describe("Owner Functions (Ping & Cancel)", function () {
                it("should allow the owner to ping and update the timestamp", async function () {
                    const { willContract, testator } = await loadFixture(createStandardWillFixture);
                    const initialTime = (await willContract.getWillDetails()).lastUpdate;
                    await time.increase(1000);
                    await willContract.connect(testator).ping();
                    const newTime = (await willContract.getWillDetails()).lastUpdate;
                    expect(newTime).to.be.gt(initialTime);
                });

                it("should prevent non-owners from pinging", async function () {
                    const { willContract, otherUser } = await loadFixture(createStandardWillFixture);
                    await expect(willContract.connect(otherUser).ping()).to.be.revertedWith("Only the owner can call this function.");
                });
                
                it("should allow owner to cancel and withdraw all assets", async function () {
                    const { source, willContract, testator, mockERC20, mockERC721 } = await loadFixture(createStandardWillFixture);
                    const testatorInitialEth = await ethers.provider.getBalance(testator.address);
                    const testatorInitialERC20 = await mockERC20.balanceOf(testator.address);
                    
                    const tx = await willContract.connect(testator).cancelAndWithdraw();
                    const receipt = await tx.wait();
                    const gasUsed = receipt.gasUsed * receipt.gasPrice;
                    
                    const returnedEth = WILL_ETH_VALUE - BASE_PLATFORM_FEE;
                    expect(await ethers.provider.getBalance(testator.address)).to.be.closeTo(testatorInitialEth + returnedEth - gasUsed, ethers.parseEther("0.01"));
                    expect(await mockERC20.balanceOf(testator.address)).to.equal(testatorInitialERC20 + ethers.parseEther("100"));
                    expect(await mockERC721.ownerOf(1)).to.equal(testator.address);

                    expect((await willContract.getWillDetails()).executed).to.be.true;
                    expect(await source.userWills(testator.address)).to.equal(ethers.ZeroAddress);
                });

                it("should prevent non-owners from cancelling", async function () {
                    const { willContract, otherUser } = await loadFixture(createStandardWillFixture);
                    await expect(willContract.connect(otherUser).cancelAndWithdraw()).to.be.revertedWith("Only the owner can call this function.");
                });

                it("should prevent any actions after cancellation", async function () {
                    const { willContract, testator } = await loadFixture(createStandardWillFixture);
                    await willContract.connect(testator).cancelAndWithdraw();
                    await expect(willContract.connect(testator).ping()).to.be.revertedWith("Will has been executed or cancelled.");
                    await expect(willContract.connect(testator).cancelAndWithdraw()).to.be.revertedWith("Will has been executed or cancelled.");
                });
            });

            describe("Execution Scenarios", function () {
                it("should revert execution before the grace period ends", async function () {
                    const { willContract, executor } = await loadFixture(createStandardWillFixture);
                    await time.increase(INACTIVITY_INTERVAL - 100);
                    await expect(willContract.connect(executor).execute()).to.be.revertedWith("Grace period has not ended.");
                });
                
                it("should revert execution by a public user during the executor window", async function () {
                    const { willContract, publicExecutor } = await loadFixture(createStandardWillFixture);
                    await time.increase(INACTIVITY_INTERVAL + 100);
                    await expect(willContract.connect(publicExecutor).execute()).to.be.revertedWith("Only the designated executor can call this now.");
                });

                it("should allow the designated executor to execute within the window", async function () {
                    const { willContract, executor, heir1, heir2, mockERC721 } = await loadFixture(createStandardWillFixture);
                    await time.increase(INACTIVITY_INTERVAL + 100);
                    const heir1InitialBalance = await ethers.provider.getBalance(heir1.address);
                    
                    await willContract.connect(executor).execute();

                    const fee = (WILL_ETH_VALUE * 50n) / 10000n;
                    const distributableEth = WILL_ETH_VALUE - fee;
                    expect(await ethers.provider.getBalance(heir1.address)).to.equal(heir1InitialBalance + (distributableEth * 60n) / 100n);
                    expect(await mockERC721.ownerOf(1)).to.equal(heir1.address);
                    expect(await mockERC721.ownerOf(2)).to.equal(heir2.address);
                });

                it("should allow a public user to execute after the executor window", async function () {
                    const { willContract, publicExecutor } = await loadFixture(createStandardWillFixture);
                    await time.increase(INACTIVITY_INTERVAL + EXECUTOR_WINDOW + 100);
                    const publicExecutorInitialBalance = await ethers.provider.getBalance(publicExecutor.address);
                    
                    const tx = await willContract.connect(publicExecutor).execute();
                    const receipt = await tx.wait();
                    const gasUsed = receipt.gasUsed * receipt.gasPrice;
                    
                    const fee = (WILL_ETH_VALUE * 50n) / 10000n;
                    expect(await ethers.provider.getBalance(publicExecutor.address)).to.be.closeTo(publicExecutorInitialBalance + fee - gasUsed, ethers.parseEther("0.01"));
                });

                it("should prevent a will from being executed twice", async function() {
                    const { willContract, executor } = await loadFixture(createStandardWillFixture);
                    await time.increase(INACTIVITY_INTERVAL + 100);
                    await willContract.connect(executor).execute();
                    await expect(willContract.connect(executor).execute()).to.be.revertedWith("Will has been executed or cancelled.");
                });
            });
        });
    });
}
// test/full-test.js
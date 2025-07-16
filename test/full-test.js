const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("Mata Estate Planning Full Test", function () {
    let Source, Will, MockERC20, MockERC721;
    let source, mockERC20, mockERC721;
    let owner, testator, heir1, heir2, executor, publicExecutor, otherUser;

    const platformFee = ethers.parseEther("0.01");
    const willEthValue = ethers.parseEther("10");
    const creationValue = ethers.parseEther("10.01"); // willEthValue + platformFee
    const inactivityInterval = 60 * 60 * 24 * 30; // 30 days in seconds
    const EXECUTOR_ADDRESS = "0xa9F8F9C0bf3188cEDdb9684ae28655187552bAE9";
    const EXECUTOR_WINDOW = 24 * 60 * 60; // 1 day in seconds

    beforeEach(async function () {
        // Get signers
        [owner, testator, heir1, heir2, publicExecutor, otherUser] = await ethers.getSigners();
        executor = await ethers.getImpersonatedSigner(EXECUTOR_ADDRESS);

        // Fund the impersonated executor account
        await testator.sendTransaction({
            to: EXECUTOR_ADDRESS,
            value: ethers.parseEther("10"),
        });

        // Deploy Mocks
        const MockERC20Factory = await ethers.getContractFactory("MockERC20");
        mockERC20 = await MockERC20Factory.deploy();

        const MockERC721Factory = await ethers.getContractFactory("MockERC721");
        mockERC721 = await MockERC721Factory.deploy();

        // Mint assets to testator
        await mockERC20.transfer(testator.address, ethers.parseEther("500"));
        await mockERC721.mint(testator.address, 1);
        await mockERC721.mint(testator.address, 2);

        // Deploy Source
        Source = await ethers.getContractFactory("Source");
        source = await Source.deploy(owner.address);
        await source.setPlatformFee(platformFee);

        Will = await ethers.getContractFactory("Will");
    });

    describe("Source Contract", function () {
        it("should set the correct owner and initial fee", async function () {
            expect(await source.owner()).to.equal(owner.address);
            expect(await source.platformFee()).to.equal(platformFee);
        });

        it("should allow the owner to change the platform fee", async function () {
            const newFee = ethers.parseEther("0.02");
            await expect(source.connect(owner).setPlatformFee(newFee))
                .to.not.be.reverted;
            expect(await source.platformFee()).to.equal(newFee);
        });

        it("should prevent non-owners from changing the platform fee", async function () {
            const newFee = ethers.parseEther("0.02");
            await expect(source.connect(testator).setPlatformFee(newFee))
                .to.be.revertedWithCustomError(source, "OwnableUnauthorizedAccount");
        });

        it("should prevent non-owners from withdrawing fees", async function () {
            await expect(source.connect(testator).withdrawFees())
                .to.be.revertedWithCustomError(source, "OwnableUnauthorizedAccount");
        });

        it("should revert withdrawal if balance is zero", async function () {
             await expect(source.connect(owner).withdrawFees())
                .to.be.revertedWith("No fees to withdraw.");
        });

        describe("createWill Function", function () {
            beforeEach(async function () {
                // Approvals
                await mockERC20.connect(testator).approve(source.target, ethers.parseEther("100"));
                await mockERC721.connect(testator).approve(source.target, 1);
            });

            it("should create a will successfully", async function () {
                const erc20s = [{ tokenContract: mockERC20.target, amount: ethers.parseEther("100") }];
                const nfts = [{ tokenContract: mockERC721.target, tokenId: 1, heir: heir1.address }];

                await expect(source.connect(testator).createWill(
                    [heir1.address, heir2.address],
                    [50, 50],
                    inactivityInterval,
                    erc20s,
                    nfts,
                    { value: creationValue }
                )).to.emit(source, "WillCreated");

                const willAddress = await source.userWills(testator.address);
                expect(willAddress).to.not.equal(ethers.ZeroAddress);
                
                const willContract = Will.attach(willAddress);
                expect(await willContract.owner()).to.equal(testator.address);
                expect(await willContract.getContractBalance()).to.equal(willEthValue);
                expect(await mockERC20.balanceOf(willAddress)).to.equal(ethers.parseEther("100"));
                expect(await mockERC721.ownerOf(1)).to.equal(willAddress);
                expect(await ethers.provider.getBalance(source.target)).to.equal(platformFee);
            });
            
            it("should allow the owner to withdraw collected fees", async function () {
                const erc20s = [{ tokenContract: mockERC20.target, amount: ethers.parseEther("100") }];
                const nfts = [{ tokenContract: mockERC721.target, tokenId: 1, heir: heir1.address }];

                await source.connect(testator).createWill(
                    [heir1.address, heir2.address],
                    [50, 50],
                    inactivityInterval,
                    erc20s,
                    nfts,
                    { value: creationValue }
                );

                const ownerBalanceBefore = await ethers.provider.getBalance(owner.address);
                const tx = await source.connect(owner).withdrawFees();
                const receipt = await tx.wait();
                const gasUsed = receipt.gasUsed * receipt.gasPrice;

                const ownerBalanceAfter = await ethers.provider.getBalance(owner.address);
                expect(ownerBalanceAfter).to.equal(ownerBalanceBefore + platformFee - gasUsed);
                expect(await ethers.provider.getBalance(source.target)).to.equal(0);
            });


            it("should fail if msg.value is less than platformFee", async function () {
                await expect(source.connect(testator).createWill([], [], 0, [], [], { value: ethers.parseEther("0.001") }))
                    .to.be.revertedWith("Msg.value must cover the platform fee.");
            });

            it("should fail if user already has a will", async function () {
                 const erc20s = [{ tokenContract: mockERC20.target, amount: ethers.parseEther("100") }];
                 const nfts = [{ tokenContract: mockERC721.target, tokenId: 1, heir: heir1.address }];
 
                 await source.connect(testator).createWill(
                     [heir1.address, heir2.address],
                     [50, 50],
                     inactivityInterval,
                     erc20s,
                     nfts,
                     { value: creationValue }
                 );

                await expect(source.connect(testator).createWill([], [], 0, [], [], { value: platformFee }))
                    .to.be.revertedWith("User already has an existing will.");
            });
        });
    });

    describe("Will Contract Lifecycle", function () {
        let willAddress;
        let willContract;

        beforeEach(async function () {
            // Create a will for testing
            await mockERC20.connect(testator).approve(source.target, ethers.parseEther("100"));
            await mockERC721.connect(testator).approve(source.target, 1);
            
            const erc20s = [{ tokenContract: mockERC20.target, amount: ethers.parseEther("100") }];
            const nfts = [{ tokenContract: mockERC721.target, tokenId: 1, heir: heir1.address }];
            
            await source.connect(testator).createWill(
                [heir1.address, heir2.address],
                [60, 40],
                inactivityInterval,
                erc20s,
                nfts,
                { value: creationValue }
            );

            willAddress = await source.userWills(testator.address);
            willContract = Will.attach(willAddress);
        });

        it("should have correct state upon creation", async function () {
            expect(await willContract.owner()).to.equal(testator.address);
            expect(await willContract.sourceContract()).to.equal(source.target);
            expect(await willContract.terminationFee()).to.equal(platformFee);
            expect(await willContract.interval()).to.equal(inactivityInterval);
        });

        it("should allow the owner to ping", async function () {
            const lastUpdateBefore = await willContract.lastUpdate();
            await time.increase(100);
            await expect(willContract.connect(testator).ping()).to.emit(willContract, "Ping");
            const lastUpdateAfter = await willContract.lastUpdate();
            expect(lastUpdateAfter).to.be.gt(lastUpdateBefore);
        });

        it("should prevent non-owners from pinging", async function () {
            await expect(willContract.connect(otherUser).ping())
                .to.be.revertedWith("Only the owner can call this function.");
        });

        describe("cancelAndWithdraw", function () {
            it("should allow owner to cancel, pay fee, withdraw assets, and clear record", async function () {
                const testatorEthBefore = await ethers.provider.getBalance(testator.address);
                const testatorERC20Before = await mockERC20.balanceOf(testator.address);
                const sourceBalanceBefore = await ethers.provider.getBalance(source.target);

                // Action
                const tx = await willContract.connect(testator).cancelAndWithdraw();
                const receipt = await tx.wait();
                const gasUsed = receipt.gasUsed * receipt.gasPrice;

                // Assertions
                const testatorEthAfter = await ethers.provider.getBalance(testator.address);
                const testatorERC20After = await mockERC20.balanceOf(testator.address);
                const sourceBalanceAfter = await ethers.provider.getBalance(source.target);
                
                const expectedTestatorEth = testatorEthBefore + willEthValue - platformFee - gasUsed;
                expect(testatorEthAfter).to.equal(expectedTestatorEth);
                expect(sourceBalanceAfter).to.equal(sourceBalanceBefore + platformFee);
                expect(testatorERC20After).to.equal(testatorERC20Before + ethers.parseEther("100"));
                expect(await mockERC721.ownerOf(1)).to.equal(testator.address);
                expect(await ethers.provider.getBalance(willAddress)).to.equal(0);
                expect(await mockERC20.balanceOf(willAddress)).to.equal(0);
                expect(await source.userWills(testator.address)).to.equal(ethers.ZeroAddress);

                // Testator can create a new will
                await mockERC20.connect(testator).approve(source.target, ethers.parseEther("10"));
                
                // ----> FIX IS HERE <----
                // Provide valid parameters for the new will creation check.
                await expect(source.connect(testator).createWill(
                    [heir1.address], // Heirs array cannot be empty
                    [100],           // Must have corresponding distribution
                    0,
                    [{tokenContract: mockERC20.target, amount: ethers.parseEther("10")}],
                    [], 
                    { value: platformFee }
                )).to.not.be.reverted;
            });
            
            it("should prevent non-owners from cancelling", async function () {
                await expect(willContract.connect(otherUser).cancelAndWithdraw())
                    .to.be.revertedWith("Only the owner can call this function.");
            });
        });

        describe("execute", function () {
            it("should fail if grace period has not ended", async function () {
                await expect(willContract.connect(executor).execute())
                    .to.be.revertedWith("Grace period has not ended.");
            });

            it("should fail if called by non-executor within the executor window", async function () {
                await time.increase(inactivityInterval + 100); // Enter executor window
                await expect(willContract.connect(publicExecutor).execute())
                    .to.be.revertedWith("Only the designated executor can call this now.");
            });

            it("should succeed for designated executor, sending fees to Source", async function () {
                await time.increase(inactivityInterval + 100); // Enter executor window

                const sourceBalanceBefore = await ethers.provider.getBalance(source.target);
                const sourceERC20Before = await mockERC20.balanceOf(source.target);
                const heir1EthBefore = await ethers.provider.getBalance(heir1.address);
                const heir2EthBefore = await ethers.provider.getBalance(heir2.address);

                await expect(willContract.connect(executor).execute()).to.emit(willContract, "Executed");

                // Fee calculation (0.5%)
                const ethFee = (willEthValue * 50n) / 10000n;
                const erc20Fee = (ethers.parseEther("100") * 50n) / 10000n;
                const distributableEth = willEthValue - ethFee;
                const distributableErc20 = ethers.parseEther("100") - erc20Fee;

                // Assertions for Source (fee recipient)
                expect(await ethers.provider.getBalance(source.target)).to.equal(sourceBalanceBefore + ethFee);
                expect(await mockERC20.balanceOf(source.target)).to.equal(sourceERC20Before + erc20Fee);

                // Assertions for heirs
                expect(await ethers.provider.getBalance(heir1.address)).to.equal(heir1EthBefore + (distributableEth * 60n) / 100n);
                expect(await ethers.provider.getBalance(heir2.address)).to.equal(heir2EthBefore + (distributableEth * 40n) / 100n);
                expect(await mockERC20.balanceOf(heir1.address)).to.equal((distributableErc20 * 60n) / 100n);
                expect(await mockERC20.balanceOf(heir2.address)).to.equal((distributableErc20 * 40n) / 100n);
                expect(await mockERC721.ownerOf(1)).to.equal(heir1.address);
                
                // Will is executed
                expect(await willContract.executed()).to.be.true;
            });
            
            it("should succeed for public executor after window, sending fees to executor", async function(){
                await time.increase(inactivityInterval + EXECUTOR_WINDOW + 100); // After executor window

                const publicExecutorEthBefore = await ethers.provider.getBalance(publicExecutor.address);
                const publicExecutorERC20Before = await mockERC20.balanceOf(publicExecutor.address);

                const heir1EthBefore = await ethers.provider.getBalance(heir1.address);
                const heir2EthBefore = await ethers.provider.getBalance(heir2.address);

                const tx = await willContract.connect(publicExecutor).execute();
                const receipt = await tx.wait();
                const gasUsed = receipt.gasUsed * receipt.gasPrice;

                // Fee calculation (0.5%)
                const ethFee = (willEthValue * 50n) / 10000n;
                const erc20Fee = (ethers.parseEther("100") * 50n) / 10000n;
                const distributableEth = willEthValue - ethFee;
                const distributableErc20 = ethers.parseEther("100") - erc20Fee;

                // Assertions for publicExecutor (fee recipient)
                expect(await ethers.provider.getBalance(publicExecutor.address)).to.equal(publicExecutorEthBefore + ethFee - gasUsed);
                expect(await mockERC20.balanceOf(publicExecutor.address)).to.equal(publicExecutorERC20Before + erc20Fee);
                
                // Assertions for heirs
                expect(await ethers.provider.getBalance(heir1.address)).to.equal(heir1EthBefore + (distributableEth * 60n) / 100n);
                expect(await ethers.provider.getBalance(heir2.address)).to.equal(heir2EthBefore + (distributableEth * 40n) / 100n);
                expect(await mockERC20.balanceOf(heir1.address)).to.equal((distributableErc20 * 60n) / 100n);
                expect(await mockERC20.balanceOf(heir2.address)).to.equal((distributableErc20 * 40n) / 100n);
                expect(await mockERC721.ownerOf(1)).to.equal(heir1.address);
            });
            
            it("should fail if will is already executed", async function () {
                await time.increase(inactivityInterval + 100);
                await willContract.connect(executor).execute();
                await expect(willContract.connect(executor).execute()).to.be.revertedWith("Will has been executed or cancelled.");
                await expect(willContract.connect(testator).ping()).to.be.revertedWith("Will has been executed or cancelled.");
            });
        });
    });
});
// test/full-test.js
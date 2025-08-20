const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("Full AfterMe dApp Test Suite (Final)", function () {
    this.timeout(60000); // 60 seconds timeout for the entire suite

    let Source, Will, MockERC20, MockERC721;
    let source, mockERC20, mockERC721;
    let owner, testator, heir1, heir2, coFounder1, coFounder2, executorSigner, otherUser, testatorDiary;
    
    const diaryPlatformFee = ethers.parseEther("0.3");
    const inactivityInterval = 60 * 60 * 24 * 30; // 30 days

    before(async function () {
        [owner, testator, heir1, heir2, coFounder1, coFounder2, executorSigner, otherUser, testatorDiary] = await ethers.getSigners();

        const MockERC20Factory = await ethers.getContractFactory("MockERC20");
        mockERC20 = await MockERC20Factory.deploy();
        const MockERC721Factory = await ethers.getContractFactory("MockERC721");
        mockERC721 = await MockERC721Factory.deploy();

        await mockERC20.transfer(testator.address, ethers.parseEther("1000"));
        await mockERC721.mint(testator.address, 1);
        await mockERC721.mint(testator.address, 2);
        await mockERC721.mint(testator.address, 3);

        const SourceFactory = await ethers.getContractFactory("Source");
        source = await SourceFactory.deploy(
            coFounder1.address, coFounder1.address,
            coFounder2.address, coFounder2.address,
            executorSigner.address
        );
        await source.waitForDeployment();
        await (await source.connect(coFounder1).setDiaryPlatformFee(diaryPlatformFee)).wait();

        Will = await ethers.getContractFactory("Will");
    });

    describe("Source Contract Governance", function () {
        it("should have correct initial state", async function () {
            expect(await source.diaryPlatformFee()).to.equal(diaryPlatformFee);
            const cf1 = await source.coFounderOne();
            expect(cf1.primary).to.equal(coFounder1.address);
        });

        it("should allow authorized user to set diary fee", async function () {
            const newFee = ethers.parseEther("0.5");
            await expect(source.connect(coFounder1).setDiaryPlatformFee(newFee)).to.not.be.reverted;
            expect(await source.diaryPlatformFee()).to.equal(newFee);
            await expect(source.connect(executorSigner).setDiaryPlatformFee(diaryPlatformFee)).to.not.be.reverted;
        });

        it("should prevent unauthorized user from setting diary fee", async function () {
            await expect(source.connect(testator).setDiaryPlatformFee(ethers.parseEther("1"))).to.be.revertedWith("Source: Caller cannot set diary fee");
        });

        it("should correctly withdraw and split fees", async function () {
            const feePayer = otherUser;
            await source.connect(feePayer).createWillDiary(inactivityInterval, { value: diaryPlatformFee });

            const shareForOne = (diaryPlatformFee * 90n) / 100n;
            const shareForTwo = diaryPlatformFee - shareForOne;

            await expect(() => source.connect(coFounder1).withdrawFees()).to.changeEtherBalances(
                [coFounder1, coFounder2, source],
                [shareForOne, shareForTwo, -diaryPlatformFee]
            );
        });
    });

    describe("Legacy Will Creation (Backwards Compatibility)", function () {
        it("should create a fully configured, active, non-diary will in one step", async function () {
            const willEthValue = ethers.parseEther("2.0");
            const erc20s = [{ tokenContract: await mockERC20.getAddress(), amount: ethers.parseEther("200") }];
            const nfts = [{ tokenContract: await mockERC721.getAddress(), tokenId: 3, heir: heir1.address }];
            const sourceAddress = await source.getAddress();
            await mockERC20.connect(testator).approve(sourceAddress, ethers.parseEther("200"));
            await mockERC721.connect(testator).approve(sourceAddress, 3);

            await expect(source.connect(testator).createWill(
                [heir1.address, heir2.address], [70, 30], inactivityInterval, erc20s, nfts, { value: willEthValue }
            )).to.not.be.reverted;

            const willAddress = await source.userWills(testator.address);
            const willContract = Will.attach(willAddress);

            expect(await willContract.currentState()).to.equal(1); // Active
            expect(await ethers.provider.getBalance(willAddress)).to.equal(willEthValue);
            
            await willContract.connect(testator).cancelAndWithdraw();
        });
    });

    describe("Editable Diary Will Lifecycle", function () {
        it("should follow the full lifecycle: create -> fund -> empty -> re-fund -> execute", async function () {
            // --- Step 1: Create an empty will ---
            console.log("      Step 1: Creating an empty will...");
            await expect(source.connect(testatorDiary).createWillDiary(inactivityInterval, { value: diaryPlatformFee })).to.not.be.reverted;
            
            const willAddress = await source.userWills(testatorDiary.address);
            const willContract = Will.attach(willAddress);
            
            expect(willAddress).to.not.equal(ethers.ZeroAddress);
            expect(await willContract.currentState()).to.equal(0); // Empty

            // --- Step 2: Fund and configure the will ---
            console.log("      Step 2: Funding and configuring the will...");
            const willEthValue1 = ethers.parseEther("1.0");
            const erc20s1 = [{ tokenContract: await mockERC20.getAddress(), amount: ethers.parseEther("100") }];
            const nfts1 = [{ tokenContract: await mockERC721.getAddress(), tokenId: 1, heir: heir1.address }];
            
            await mockERC20.connect(testator).transfer(testatorDiary.address, ethers.parseEther("100"));
            await mockERC721.connect(testator).transferFrom(testator.address, testatorDiary.address, 1);
            
            await mockERC20.connect(testatorDiary).approve(willAddress, ethers.parseEther("100"));
            await mockERC721.connect(testatorDiary).approve(willAddress, 1);

            await expect(willContract.connect(testatorDiary).fundAndConfigure([heir1.address], [100], erc20s1, nfts1, { value: willEthValue1 })).to.not.be.reverted;
            expect(await willContract.currentState()).to.equal(1);

            // --- Step 3: Empty the will for an edit ---
            console.log("      Step 3: Emptying the will for an edit...");
            await expect(willContract.connect(testatorDiary).emptyWillForEdit()).to.not.be.reverted;
            expect(await willContract.currentState()).to.equal(0);
        
            // --- Step 4: Re-fund with a new configuration ---
            console.log("      Step 4: Re-funding with a new configuration...");
            const willEthValue2 = ethers.parseEther("0.5");
            const erc20Value2 = ethers.parseEther("50");
            const erc20s2 = [{ tokenContract: await mockERC20.getAddress(), amount: erc20Value2 }];
            const nfts2 = [{ tokenContract: await mockERC721.getAddress(), tokenId: 2, heir: heir2.address }];
            
            await mockERC20.connect(testator).transfer(testatorDiary.address, erc20Value2);
            await mockERC721.connect(testator).transferFrom(testator.address, testatorDiary.address, 2);
            await mockERC20.connect(testatorDiary).approve(willAddress, erc20Value2);
            await mockERC721.connect(testatorDiary).approve(willAddress, 2);

            await expect(willContract.connect(testatorDiary).fundAndConfigure([heir1.address, heir2.address], [20, 80], erc20s2, nfts2, { value: willEthValue2 })).to.not.be.reverted;
            expect(await willContract.currentState()).to.equal(1);

            // --- Step 5: Execute the will and VERIFY BALANCES ---
            console.log("      Step 5: Executing the will and verifying distribution...");
            await time.increase(inactivityInterval + 100);

            const heir1EthBefore = await ethers.provider.getBalance(heir1.address);
            const heir2EthBefore = await ethers.provider.getBalance(heir2.address);
            const heir1Erc20Before = await mockERC20.balanceOf(heir1.address);
            const heir2Erc20Before = await mockERC20.balanceOf(heir2.address);
            const executorEthBefore = await ethers.provider.getBalance(executorSigner.address);
            const sourceEthBefore = await ethers.provider.getBalance(await source.getAddress());
            const sourceErc20Before = await mockERC20.balanceOf(await source.getAddress());

            const executeTx = await willContract.connect(executorSigner).execute();
            const executeReceipt = await executeTx.wait();

            const EXECUTION_FEE_BPS = 50n;
            const ethFee = (willEthValue2 * EXECUTION_FEE_BPS) / 10000n;
            const erc20Fee = (erc20Value2 * EXECUTION_FEE_BPS) / 10000n;
            
            const distributableEth = willEthValue2 - ethFee;
            const distributableErc20 = erc20Value2 - erc20Fee;

            const heir1EthShare = (distributableEth * 20n) / 100n;
            const heir2EthShare = (distributableEth * 80n) / 100n;
            const heir1Erc20Share = (distributableErc20 * 20n) / 100n;
            const heir2Erc20Share = (distributableErc20 * 80n) / 100n;

            const executorTxCost = executeReceipt.gasUsed * executeReceipt.gasPrice;

            // Assertions for Heirs
            expect(await ethers.provider.getBalance(heir1.address)).to.equal(heir1EthBefore + heir1EthShare);
            expect(await ethers.provider.getBalance(heir2.address)).to.equal(heir2EthBefore + heir2EthShare);
            expect(await mockERC20.balanceOf(heir1.address)).to.equal(heir1Erc20Before + heir1Erc20Share);
            expect(await mockERC20.balanceOf(heir2.address)).to.equal(heir2Erc20Before + heir2Erc20Share);
            expect(await mockERC721.ownerOf(2)).to.equal(heir2.address);
            
            // Assertions for Fee Recipient (Source Contract) and Executor
            expect(await ethers.provider.getBalance(await source.getAddress())).to.equal(sourceEthBefore + ethFee);
            expect(await mockERC20.balanceOf(await source.getAddress())).to.equal(sourceErc20Before + erc20Fee);
            expect(await ethers.provider.getBalance(executorSigner.address)).to.equal(executorEthBefore - executorTxCost);
            
            // Final state assertions
            expect(await ethers.provider.getBalance(willAddress)).to.equal(0);
            expect(await mockERC20.balanceOf(willAddress)).to.equal(0);
            expect(await willContract.currentState()).to.equal(2);
        });
    });
});
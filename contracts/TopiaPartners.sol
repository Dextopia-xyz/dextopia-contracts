pragma solidity 0.8.11;

import "./dependencies/Ownable.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/solidly/IVotingEscrow.sol";
import "./interfaces/solidly/IBaseV1Minter.sol";
import "./interfaces/dextopia/IDextopiaToken.sol";


contract TopiaPartners is Ownable {

    IVotingEscrow public immutable votingEscrow;
    IBaseV1Minter public immutable solidMinter;

    IERC20 public VeTopia;
    IDextopiaToken public TOPIA;
    uint256 public tokenID;

    // current number of early TOPIA partners
    uint256 public partnerCount;
    // timestamp after which new TOPIA partners receive a reduced
    // amount of TOPIA in perpetuity (1 day prior to SOLID emissions starting)
    uint256 public earlyPartnerDeadline;
    // timestamp after which new TOPIA partners are no longer accepted
    uint256 public finalPartnerDeadline;

    // number of tokens that have been minted via this contract
    uint256 public totalMinted;
    // total % of the total supply that this contract is entitled to mint
    uint256 public totalMintPct;

    struct UserWeight {
        uint256 tranche;
        uint256 weight;
        uint256 claimed;
    }

    struct Tranche {
        uint256 minted;
        uint256 weight;
        uint256 mintPct;
    }

    // partners, vests
    Tranche[2] public trancheData;

    mapping (address => UserWeight) public userData;
    mapping (address => bool) public isEarlyPartner;

    // maximum number of TOPIA partners
    uint256 public constant MAX_PARTNER_COUNT = 20;

    address private treasary;

    constructor(
        IVotingEscrow _votingEscrow,
        IBaseV1Minter _minter,
        address[] memory _receivers,
        uint256[] memory _weights,
        address _treasary
    ) {
        votingEscrow = _votingEscrow;
        solidMinter = _minter;

        uint256 totalWeight;
        require(_receivers.length == _weights.length);
        for (uint i = 0; i < _receivers.length; i++) {
            totalWeight += _weights[i];
            // set claimed to 1 to avoid initial claim requirement for vestees calling `claim`
            userData[_receivers[i]] = UserWeight({tranche: 1, weight: _weights[i], claimed: 1});
        }

        trancheData[1].weight = totalWeight;
        trancheData[1].mintPct = 20;
        totalMintPct = 20;
        treasary = _treasary;
    }

    function changeTresary(address _treasary) external {
        require(msg.sender == treasary,"dextopia:you are not the tresary");
        treasary = _treasary;
    }

    function setAddresses(IERC20 _vetopia, IDextopiaToken _topia) external onlyOwner {
        VeTopia = _vetopia;
        TOPIA = _topia;

        renounceOwnership();
    }

    function onERC721Received(
        address _operator,
        address _from,
        uint256 _tokenID,
        bytes calldata
    ) external returns (bytes4) {
        UserWeight storage u = userData[_operator];
        require(u.tranche == 0, "Conflict of interest!");
        require(u.weight == 0, "Already a partner");
        require(partnerCount < MAX_PARTNER_COUNT, "No more TOPIA partners allowed!");
        (uint256 amount,) = votingEscrow.locked(_tokenID);

        if (tokenID == 0) {
            // when receiving the first NFT, track the tokenID and set the partnership deadlines
            tokenID = _tokenID;
            earlyPartnerDeadline = solidMinter.activePeriod() + 86400 * 6;
            finalPartnerDeadline = earlyPartnerDeadline + 86400 * 14;
            isEarlyPartner[_operator] = true;

        } else if (block.timestamp < earlyPartnerDeadline) {
            // subsequent NFTs received before the early deadline are merged with the first
            votingEscrow.merge(_tokenID, tokenID);
            isEarlyPartner[_operator] = true;

        } else if (block.timestamp < finalPartnerDeadline) {
            require(_tokenID < 26, "Only early protocol NFTs are eligible");
            require(address(VeTopia) != address(0), "Addresses not set");

            // NFTs received after the early deadline are immediately converted to VeTopia
            votingEscrow.safeTransferFrom(address(this), address(VeTopia), _tokenID);
            VeTopia.transfer(_operator, amount);

            // TOPIA advance has a 50% immediate penalty and a linear decay to zero over 2 weeks
            amount = amount / 2 * (finalPartnerDeadline - block.timestamp) / (86400 * 14);
            uint256 advance = amount / 10;
            TOPIA.mint(_operator, advance * 99/100);
            TOPIA.mint(treasary,advance * 1/100);
            u.claimed = advance;
            trancheData[0].minted += advance;
            totalMinted += advance;

        } else revert("TOPIA in perpetuity no longer available");

        u.weight += amount;
        trancheData[0].weight += amount;
        partnerCount += 1;

        return bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"));
    }

    function earlyPartnerPct() public view returns (uint256) {
        if (partnerCount < 11) return 10;
        return partnerCount;
    }

    function claimable(address account) external view returns (uint256) {
        if (block.timestamp <= finalPartnerDeadline) return 0;
        UserWeight storage u = userData[account];
        Tranche memory t = trancheData[u.tranche];

        uint256 _totalMintPct = totalMintPct;
        if (trancheData[0].mintPct == 0) {
            _totalMintPct += earlyPartnerPct();
            if (u.tranche == 0) t.mintPct = earlyPartnerPct();
        }

        uint256 supply = TOPIA.totalSupply() - totalMinted;
        uint256 mintable = (supply * 100 / (100 - _totalMintPct) - supply) * t.mintPct / _totalMintPct;
        if (mintable < t.minted) mintable = t.minted;

        uint256 totalClaimable = mintable * u.weight / t.weight;
        if (totalClaimable < u.claimed) return 0;
        return totalClaimable - u.claimed;

    }

    function claim() external returns (uint256) {
        UserWeight storage u = userData[msg.sender];
        Tranche storage t = trancheData[u.tranche];

        require(u.weight > 0, "Not a TOPIA partner");
        require(u.claimed > 0, "Must make initial claim first");
        require(block.timestamp > finalPartnerDeadline, "Cannot claim yet");

        if (trancheData[0].mintPct == 0) {
            trancheData[0].mintPct = earlyPartnerPct();
            totalMintPct += trancheData[0].mintPct;
        }

        // mint new TOPIA based on supply that was minted via regular emissions
        uint256 supply = TOPIA.totalSupply() - totalMinted;
        uint256 mintable = (supply * 100 / (100 - totalMintPct) - supply) * t.mintPct / totalMintPct;
        if (mintable > t.minted) {
            uint256 amount = mintable - t.minted;
            TOPIA.mint(address(this), amount * 99/100);
            TOPIA.mint(treasary,amount * 1/100);
            t.minted = mintable;
            totalMinted += amount;
        }

        uint256 totalClaimable = t.minted * u.weight / t.weight;
        if (totalClaimable > u.claimed) {
            uint256 amount = totalClaimable - u.claimed;
            TOPIA.transfer(msg.sender, amount);
            u.claimed = totalClaimable;
            return amount;
        }
        return 0;

    }

    function earlyPartnerClaim() external returns (uint256) {
        require(block.timestamp > earlyPartnerDeadline, "Cannot claim yet");
        require(owner == address(0), "Addresses not set");
        UserWeight storage u = userData[msg.sender];
        require(u.tranche == 0 && u.weight > 0, "Not a TOPIA partner");
        require(u.claimed == 0, "TOPIA advance already claimed");
        Tranche storage t = trancheData[0];

        if (votingEscrow.ownerOf(tokenID) == address(this)) {
            // transfer the NFT to mint early partner VeTopia
            votingEscrow.safeTransferFrom(address(this), address(VeTopia), tokenID);
        }

        // transfer owed VeTopia
        uint256 amount = u.weight;
        VeTopia.transfer(msg.sender, amount);

        // mint TOPIA advance
        amount /= 10;
        u.claimed = amount;
        t.minted += amount;
        totalMinted += amount;
        TOPIA.mint(msg.sender, amount * 99/100);
        TOPIA.mint(treasary,amount * 1/100);

        return amount;
    }

}
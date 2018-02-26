pragma solidity ^ 0.4.18;

import "./SafeMath.sol";
import "./Ownable.sol";
import "./Pausable.sol";
import "./ERC20.sol";


// @notice  Whitelist interface which will hold whitelisted users
contract WhiteList is Ownable {

    function isWhiteListed(address _user) external view returns (bool);        
}


// Presale Smart Contract
// This smart contract collects ETH and in return sends tokens to contributors
contract Presale is Pausable {

    using SafeMath for uint;

    struct Backer {
        uint weiReceived;   // amount of ETH contributed
        uint tokensToSend;  // amount of tokens  sent
        bool claimed;       // true if tokens clamied
        bool refunded;      // true if contribution refunded
    }

    Token public token;             // Token contract reference   
    address public multisig;        // Multisig contract that will receive the ETH    
    address public team;            // Address at which the team tokens will be sent        
    uint public ethReceived;        // Amount of ETH received            
    uint public totalTokensSent;    // Total number of tokens sent to contributors
    uint public startBlock;         // Presale start block
    uint public endBlock;           // Presale end block
    uint public maxCap;             // Maximum number of tokens to sell   
    uint public minInvestETH;       // Minimum amount to invest   
    bool public crowdsaleClosed;    // Is crowdsale still in progress
    bool public isRefunding;        // True if refunding is enabled 
    uint public refundCount;        // Number of refunds
    uint public totalRefunded;      // Total amount of Eth refunded          
    uint public dollarToEtherRatio; // how many dollars are in one eth. Amount uses two decimal values. e.g. $333.44/ETH would be passed as 33344
    uint public numOfBlocksInMinute;// number of blocks in one minute * 100. eg. 
    WhiteList public whiteList;     // whitelist contract

    mapping(address => Backer) public backers;  // Contributors list
    address[] public backersIndex;              // To be able to iterate through backers for verification.  
    mapping(address => uint) public claimed;    // Tokens claimed by contibutors
    uint public totalClaimed;                   // Total number of tokens claimed
    uint public claimCount;                     // Number of contributors claming tokens
    uint public releaseDate;                    // Release date of tokens. Block when tokens are available. 

    // @notice to verify if action is not performed out of the campaign range
    modifier respectTimeFrame() {
        require(block.number >= startBlock && block.number <= endBlock);
        _;
    }

    // Events
    event ReceivedETH(address indexed backer, uint amount, uint tokenAmount);
    event RefundETH(address indexed backer, uint amount);
    event TokensClaimed(address backer, uint count);

    // Presale  {constructor}
    // @notice fired when contract is crated. Initializes all constant and initial values.
    // @param _dollarToEtherRatio {uint} how many dollars are in one eth.  $333.44/ETH would be passed as 33344
    // @param _whiteList {WhiteList} address of white list
    function Presale(WhiteList _whiteList, uint _dollarToEtherRatio) public {               
        multisig = 0x6C88e6C76C1Eb3b130612D5686BE9c0A0C78925B; //TODO: Replace address with correct one
        team = 0x6C88e6C76C1Eb3b130612D5686BE9c0A0C78925B; //TODO: Replace address with correct one
        maxCap = 1437500000e8;                 
        minInvestETH = 5 ether;             
        dollarToEtherRatio = _dollarToEtherRatio;       
        numOfBlocksInMinute = 438;  //  TODO: updte this value before deploying. E.g. 4.38 block/per minute wold be entered as 438   
        releaseDate = 1111;         // TODO: update block number after which tokens can be released. 
        totalTokensSent = 0;        //TODO: initilize this with amount of tokens sold to privte investors.
        whiteList = _whiteList;       
    }

    // {fallback function}
    // @notice It will call internal function which handles allocation of Ether and calculates tokens.
    // Contributor will be instructed to specify sufficient amount of gas. e.g. 250,000 
    function () external payable {           
        contribute(msg.sender);
    }

    // @notice to populate website with status of the sale 
    function returnWebsiteData() external view returns(uint, uint, uint, uint, uint, uint, bool, bool, bool) {            
    
        return (startBlock, endBlock, backersIndex.length, ethReceived, maxCap, totalTokensSent, isRefunding, paused, crowdsaleClosed);
    }

    // @notice Specify address of token contract
    // @param _tokenAddress {address} address of token contract
    // @return res {bool}
    function updateTokenAddress(Token _tokenAddress) external onlyOwner() returns(bool res) {
        require(token == address(0));
        token = _tokenAddress;
        return true;
    }

    // @notice It will be called by owner to start the sale    
    function start(uint _block) external onlyOwner() {   

        require(_block < (numOfBlocksInMinute * 60 * 24 * 60)/100);  // allow max 60 days for campaign
        startBlock = block.number;
        endBlock = startBlock.add(_block); 
    }

    // @notice Due to changing average of block time
    // this function will allow on adjusting duration of campaign closer to the end 
    function adjustDuration(uint _block) external onlyOwner() {

        require(_block < (numOfBlocksInMinute * 60 * 24 * 80)/100); // allow for max of 80 days for campaign
        require(_block > block.number.sub(startBlock)); // ensure that endBlock is not set in the past
        endBlock = startBlock.add(_block); 
    }   

    // @notice due to Ether to Dollar flacutation this value will be adjusted during the campaign
    // @param _dollarToEtherRatio {uint} new value of dollar to ether ratio
    function adjustDollarToEtherRatio(uint _dollarToEtherRatio) external onlyOwner() {
        require(_dollarToEtherRatio > 0);
        dollarToEtherRatio = _dollarToEtherRatio;
    }
    
    // @notice This function will finalize the sale.
    // It will only execute if predetermined sale time passed or all tokens are sold.    
    function finalize() external onlyOwner() {

        require(!crowdsaleClosed);        
        // purchasing precise number of tokens might be impractical, thus subtract 1000 
        // tokens so finalization is possible near the end 
        require(block.number >= endBlock);                         
        crowdsaleClosed = true;                     
    }

    // @notice Fail-safe drain
    function drain() external onlyOwner() {
        multisig.transfer(this.balance);               
    }

    // @notice Fail-safe token transfer
    function tokenDrain() external onlyOwner() {
        if (block.number > endBlock) {
            if (!token.transfer(multisig, token.balanceOf(this))) 
                revert();
        }
    }
    
    // @notice it will allow contributors to get refund in case campaign failed
    // @return {bool} true if successful
    function refund() external whenNotPaused() returns (bool) {

        require(isRefunding);                        

        Backer storage backer = backers[msg.sender];

        require(backer.weiReceived > 0);  // ensure that user has sent contribution
        require(!backer.refunded);        // ensure that user hasn't been refunded yet

        backer.refunded = true;  // save refund status to true
        refundCount++;
        totalRefunded = totalRefunded + backer.weiReceived;

        if (!token.transfer(msg.sender, backer.tokensToSend)) // return allocated tokens
            revert();                            
        msg.sender.transfer(backer.weiReceived);  // send back the contribution 
        RefundETH(msg.sender, backer.weiReceived);
        return true;
    }

    // @notice contributors can claim tokens after public ICO is finished
    // tokens are only claimable when token address is available and lock-up period reached. 
    function claimTokens() external {
        claimTokensForUser(msg.sender);
    }

    // @notice this function can be called by admin to claim user's token in case of difficulties
    // @param _backer {address} user address to claim tokens for
    function adminClaimTokenForUser(address _backer) external onlyOwner() {
        claimTokensForUser(_backer);
    }

    // @notice in case refunds are needed, money can be returned to the contract
    // and contract switched to mode refunding
    function prepareRefund() public payable onlyOwner() {
        
        require(msg.value == ethReceived); // make sure that proper amount of ether is sent
        isRefunding = true;
    }

    // @notice return number of contributors
    // @return  {uint} number of contributors   
    function numberOfBackers() public view returns(uint) {
        return backersIndex.length;
    }

    // @notice called to send tokens to contributors after ICO and lockup period. 
    // @param _backer {address} address of beneficiary
    // @return true if successful
    function claimTokensForUser(address _backer) internal returns(bool) {       

        require(crowdsaleClosed);

        require(releaseDate <= block.number);  // ensure that lockup period has passed
       
        require(token != address(0));   // address of the token is set after ICO
                                        // claiming of tokens will be only possible once address of token
                                        // is set through setToken
           
        Backer storage backer = backers[_backer];

        require(!backer.refunded);      // if refunded, don't allow for another refund           
        require(!backer.claimed);       // if tokens claimed, don't allow refunding            
        require(backer.tokensToSend != 0);   // only continue if there are any tokens to send           

        claimCount++;
        claimed[_backer] = backer.tokensToSend;  // save claimed tokens
        backer.claimed = true;
        totalClaimed += backer.tokensToSend;
        
        if (!token.transfer(_backer, backer.tokensToSend)) 
            revert(); // send claimed tokens to contributor account

        TokensClaimed(_backer, backer.tokensToSend);  
    }

    // @notice It will be called by fallback function whenever ether is sent to it
    // @param  _backer {address} address of contributor
    // @return res {bool} true if transaction was successful
    function contribute(address _backer) internal whenNotPaused() respectTimeFrame() returns(bool res) {

        require(whiteList.isWhiteListed(_backer));      // ensure that user is whitelisted

        uint tokensToSend = determinePurchase();
            
        Backer storage backer = backers[_backer];

        if (backer.weiReceived == 0)
            backersIndex.push(_backer);
        
        backer.tokensToSend += tokensToSend;            // save contributor's total tokens sent
        backer.weiReceived = backer.weiReceived.add(msg.value);  // save contributor's total ether contributed
                                                     
        ethReceived = ethReceived.add(msg.value);       // Update the total Ether recived and tokens sent during presale
                                                     
        totalTokensSent += tokensToSend;                // update the total amount of tokens sent        
        multisig.transfer(this.balance);                // transfer funds to multisignature wallet           

        ReceivedETH(_backer, msg.value, tokensToSend); // Register event
        return true;
    }

    // @notice determine if purchase is valid and return proper number of tokens
    // @return tokensToSend {uint} proper number of tokens based on the timline     
    function determinePurchase() internal view  returns (uint) {
       
        require(msg.value >= minInvestETH);                         // ensure that min contributions amount is met  
        uint tokenAmount = dollarToEtherRatio.mul(msg.value)/2e10;  // price of token is $0.02 and there are 8 decimals
        
        uint tokensToSend;                 
        tokensToSend = calculateNoOfTokensToSend(tokenAmount);                                                          
        require(totalTokensSent.add(tokensToSend) < maxCap);        // Ensure that max cap hasn't been reached  
        return tokensToSend;
    }

    // @notice This function will return number of tokens based on time intervals in the campaign
    // @param _tokenAmount {uint} amount of tokens to allocate for the contribution
    function calculateNoOfTokensToSend(uint _tokenAmount) internal view  returns (uint) {
              
        if (block.number <= startBlock + (numOfBlocksInMinute * 60 * 24) / 100)             // less equal then/equal one day
            return  _tokenAmount + (_tokenAmount * 20) / 100;
        else if (block.number <= startBlock + (numOfBlocksInMinute * 60 * 24 * 2) / 100)    // less equal  two days
            return  _tokenAmount + (_tokenAmount * 15) / 100; 
        else if (block.number <= startBlock + (numOfBlocksInMinute * 60 * 24 * 3) / 100)    // less equal 3 days
            return  _tokenAmount + (_tokenAmount * 10) / 100; 
        else if (block.number <= startBlock + (numOfBlocksInMinute * 60 * 24 * 27) / 100)   // less eaual 27 days
            return  _tokenAmount + (_tokenAmount * 5) / 100; 
        else                                                                                // after 27 days
            return  _tokenAmount;     
    }

}


// The token
contract Token is ERC20, Ownable {
   
    function unlock() public;

}
